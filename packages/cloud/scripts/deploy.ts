/**
 * Deploys `piopio-cloud` with the Cloudflare REST API and an API token, the way the app will
 * (docs/spec/02-architecture.md §5.2). Wrangler is only the bundler here (`--dry-run --outdir`);
 * the app will ship that bundle prebuilt.
 *
 *   CLOUDFLARE_API_TOKEN=… CLOUDFLARE_ACCOUNT_ID=… OWNER_TOKEN=… OPENROUTER_API_KEY=… \
 *     node scripts/deploy.ts [--skip-build] [--plan]
 *
 * Token permissions: Account › Workers Scripts › Edit (covers Durable Objects and the
 * workers.dev route). `--plan` prints what would be uploaded and makes no API calls.
 *
 * Steps: read the current migration tag → upload the script (modules, bindings, DO migrations,
 * keeping existing secrets) → set the secrets given in the environment → enable workers.dev →
 * check `/v1/health`.
 */
import { execFileSync } from "node:child_process";
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const API = "https://api.cloudflare.com/client/v4";
const SECRETS = ["OWNER_TOKEN", "OPENROUTER_API_KEY"] as const;
/** Plain-text vars passed through from the environment when set. */
const VARS = ["PIOPIO_DEFAULT_MODEL"] as const;

export type WranglerConfig = {
	name: string;
	main: string;
	compatibility_date: string;
	compatibility_flags?: string[];
	durable_objects?: { bindings: { name: string; class_name: string }[] };
	migrations?: ({ tag: string } & Record<string, unknown>)[];
	observability?: { enabled: boolean };
};

type Migrations = { old_tag?: string; new_tag: string; steps: Record<string, unknown>[] };

/** The migrations still to apply on top of the deployed tag (same rules as wrangler). */
export function pendingMigrations(config: WranglerConfig, deployedTag: string | undefined): Migrations | undefined {
	const all = config.migrations ?? [];
	if (all.length === 0) return undefined;
	const newTag = all[all.length - 1]!.tag;
	const steps = (list: typeof all) => list.map(({ tag: _tag, ...step }) => step);
	if (!deployedTag) return { new_tag: newTag, steps: steps(all) };
	const index = all.findIndex((m) => m.tag === deployedTag);
	if (index === -1) return { old_tag: deployedTag, new_tag: newTag, steps: steps(all) };
	if (index === all.length - 1) return undefined;
	return { old_tag: deployedTag, new_tag: newTag, steps: steps(all.slice(index + 1)) };
}

export type Module = { name: string; contentType: string; body: Uint8Array };

/** Script metadata for `PUT /workers/scripts/:name` (multipart part `metadata`). */
export function scriptMetadata(config: WranglerConfig, mainModule: string, migrations: Migrations | undefined, vars: Record<string, string>) {
	return {
		main_module: mainModule,
		compatibility_date: config.compatibility_date,
		compatibility_flags: config.compatibility_flags ?? [],
		bindings: [
			...(config.durable_objects?.bindings ?? []).map((b) => ({ type: "durable_object_namespace", name: b.name, class_name: b.class_name })),
			...Object.entries(vars).map(([name, text]) => ({ type: "plain_text", name, text })),
		],
		// Secrets are set separately and must survive script updates.
		keep_bindings: ["secret_text"],
		...(migrations ? { migrations } : {}),
		...(config.observability ? { observability: config.observability } : {}),
	};
}

/** The bundle wrangler wrote to `dir`: the entry module plus anything next to it. */
export function readBundle(dir: string): { main: string; modules: Module[] } {
	const modules: Module[] = [];
	for (const name of readdirSync(dir)) {
		// Source maps stay local (wrangler's default too); they would add ~10 MB to every upload.
		const contentType = name.endsWith(".js") || name.endsWith(".mjs") ? "application/javascript+module" : name.endsWith(".wasm") ? "application/wasm" : undefined;
		if (contentType) modules.push({ name, contentType, body: readFileSync(join(dir, name)) });
	}
	const main = modules.find((m) => m.name === "index.js")?.name;
	if (!main) throw new Error(`No index.js in ${dir}; build first.`);
	return { main, modules };
}

type Fetch = typeof fetch;
type Log = (line: string) => void;

export class CloudflareApi {
	private readonly token: string;
	readonly accountId: string;
	private readonly fetchImpl: Fetch;

	constructor(token: string, accountId: string, fetchImpl: Fetch = fetch) {
		this.token = token;
		this.accountId = accountId;
		this.fetchImpl = fetchImpl;
	}

	async call<T>(method: string, path: string, body?: BodyInit | object, allow404 = false): Promise<T | undefined> {
		const isJson = body !== undefined && !(body instanceof FormData) && typeof body === "object";
		const res = await this.fetchImpl(`${API}/accounts/${this.accountId}${path}`, {
			method,
			headers: { Authorization: `Bearer ${this.token}`, ...(isJson ? { "Content-Type": "application/json" } : {}) },
			...(body === undefined ? {} : { body: isJson ? JSON.stringify(body) : (body as BodyInit) }),
		});
		if (res.status === 404 && allow404) return undefined;
		const json = (await res.json().catch(() => ({}))) as { success?: boolean; result?: T; errors?: { code: number; message: string }[] };
		if (!res.ok || json.success === false) {
			const detail = json.errors?.map((e) => `${e.code}: ${e.message}`).join("; ") || res.statusText;
			throw new Error(`${method} ${path} failed (${res.status}): ${detail}`);
		}
		return json.result as T;
	}
}

export type DeployOptions = {
	api: CloudflareApi;
	config: WranglerConfig;
	bundle: { main: string; modules: Module[] };
	secrets: Partial<Record<(typeof SECRETS)[number], string>>;
	vars: Record<string, string>;
	fetchImpl?: Fetch;
	log?: Log;
};

/** Uploads the script, its secrets and its workers.dev route. Returns the Worker's URL. */
export async function deploy(options: DeployOptions): Promise<string> {
	const { api, config, bundle, secrets, vars } = options;
	const log = options.log ?? (() => {});
	const name = config.name;

	const service = await api.call<{ default_environment?: { script?: { migration_tag?: string } } }>("GET", `/workers/services/${name}`, undefined, true);
	const deployedTag = service?.default_environment?.script?.migration_tag;
	const migrations = pendingMigrations(config, deployedTag);
	log(`Uploading ${name} (${bundle.modules.length} modules; migrations ${migrations ? `${deployedTag ?? "none"} → ${migrations.new_tag}` : "up to date"})`);

	const form = new FormData();
	form.set("metadata", new Blob([JSON.stringify(scriptMetadata(config, bundle.main, migrations, vars))], { type: "application/json" }));
	for (const m of bundle.modules) form.set(m.name, new Blob([m.body as Uint8Array<ArrayBuffer>], { type: m.contentType }), m.name);
	await api.call("PUT", `/workers/scripts/${name}`, form);

	for (const [secret, text] of Object.entries(secrets)) {
		if (!text) continue;
		log(`Setting secret ${secret}`);
		await api.call("PUT", `/workers/scripts/${name}/secrets`, { name: secret, text, type: "secret_text" });
	}

	await api.call("POST", `/workers/scripts/${name}/subdomain`, { enabled: true, previews_enabled: false });
	const sub = await api.call<{ subdomain: string }>("GET", "/workers/subdomain");
	if (!sub?.subdomain) throw new Error("This account has no workers.dev subdomain yet; pick one in the dashboard (Workers & Pages) first.");
	const url = `https://${name}.${sub.subdomain}.workers.dev`;

	// A fresh workers.dev route can take a few seconds to answer.
	const fetchImpl = options.fetchImpl ?? fetch;
	for (let attempt = 0; attempt < 10; attempt++) {
		const res = await fetchImpl(`${url}/v1/health`).catch(() => undefined);
		if (res?.ok) {
			log(`Healthy: ${url}`);
			return url;
		}
		await new Promise((r) => setTimeout(r, 2_000));
	}
	throw new Error(`Deployed, but ${url}/v1/health did not answer yet.`);
}

async function main(): Promise<void> {
	const args = new Set(process.argv.slice(2));
	const root = fileURLToPath(new URL("..", import.meta.url));
	const config = JSON.parse(readFileSync(join(root, "wrangler.json"), "utf8")) as WranglerConfig;
	if (!args.has("--skip-build")) {
		execFileSync(join(root, "node_modules/.bin/wrangler"), ["deploy", "--dry-run", "--outdir", "dist"], { cwd: root, stdio: "inherit", env: { ...process.env, WRANGLER_SEND_METRICS: "false" } });
	}
	const bundle = readBundle(join(root, "dist"));
	const secrets = Object.fromEntries(SECRETS.map((s) => [s, process.env[s]]).filter(([, v]) => v)) as DeployOptions["secrets"];
	const vars = Object.fromEntries(VARS.map((v) => [v, process.env[v]]).filter(([, v]) => v)) as Record<string, string>;

	if (args.has("--plan")) {
		const metadata = scriptMetadata(config, bundle.main, pendingMigrations(config, undefined), vars);
		console.log(JSON.stringify({ metadata, modules: bundle.modules.map((m) => `${m.name} (${m.contentType}, ${m.body.byteLength} bytes)`), secrets: Object.keys(secrets) }, null, 2));
		return;
	}
	const token = process.env.CLOUDFLARE_API_TOKEN;
	const accountId = process.env.CLOUDFLARE_ACCOUNT_ID;
	if (!token || !accountId) throw new Error("Set CLOUDFLARE_API_TOKEN and CLOUDFLARE_ACCOUNT_ID.");
	const url = await deploy({ api: new CloudflareApi(token, accountId), config, bundle, secrets, vars, log: (l) => console.log(l) });
	console.log(`WebSocket: ${url.replace(/^https/, "wss")}/v1/ws?agent=<id>`);
}

if (import.meta.url === `file://${process.argv[1]}`) {
	main().catch((error) => {
		console.error(error instanceof Error ? error.message : error);
		process.exit(1);
	});
}
