/**
 * Deploys Piopio's Worker (`piopio-cloud`) with the Cloudflare REST API and an API token: no wrangler on the Mac
 * (docs/spec/13 §5.2, docs/spec/30 K1). The engine uses it for Settings › This Mac & cloud › Connect, and
 * `packages/cloud/scripts/deploy.ts` for deploys by hand. No relative imports, so the script can load this file as is.
 *
 * Steps: read the current migration tag → upload the script (modules, bindings, DO migrations, keeping existing
 * secrets) → set the secrets given → enable workers.dev (making the account's subdomain if it has none) → check
 * `/v1/health`.
 */
import { readdirSync, readFileSync } from "node:fs";
import { join } from "node:path";

const API = "https://api.cloudflare.com/client/v4";
export const SECRETS = ["OWNER_TOKEN", "OPENROUTER_API_KEY"] as const;
/** Plain-text vars passed through from the environment when set. */
export const VARS = ["PIOPIO_DEFAULT_MODEL"] as const;

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
/** Variables that only tests and `wrangler dev` may set: test routes, the faux model, test timings. */
const DEV_ONLY = /^PIOPIO_(TEST_|FAUX_)/;

export function scriptMetadata(config: WranglerConfig, mainModule: string, migrations: Migrations | undefined, vars: Record<string, string>) {
	const devOnly = Object.keys(vars).filter((v) => DEV_ONLY.test(v));
	if (devOnly.length) throw new Error(`${devOnly.join(", ")} must never be deployed: they turn on test routes or a fake model.`);
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
	/** Called when the account has no workers.dev subdomain: the name to create (none: refuse, as before). */
	subdomain?: () => string;
	/** How long to wait between health checks (tests shorten it). */
	retryMs?: number;
};

/** Uploads the script, its secrets and its workers.dev route. Returns the Worker's URL. */
export async function deploy(options: DeployOptions): Promise<string> {
	const { api, config, bundle, secrets, vars } = options;
	const log = options.log ?? (() => {});
	const name = config.name;

	const service = await api.call<{ default_environment?: { script?: { migration_tag?: string } } }>("GET", `/workers/services/${name}`, undefined, true);
	const deployedTag = service?.default_environment?.script?.migration_tag;
	// The Worker refuses everything without an owner token, so a first deploy without one would be no use.
	if (!service && !secrets.OWNER_TOKEN) throw new Error("A first deploy needs OWNER_TOKEN (for example: OWNER_TOKEN=\"$(openssl rand -hex 32)\"). Keep it: the Mac connects with it.");
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
	let sub = await api.call<{ subdomain: string }>("GET", "/workers/subdomain", undefined, true).catch(() => undefined);
	if (!sub?.subdomain && options.subdomain) {
		// A new account has no workers.dev name yet: make one, as the dashboard would on first use.
		const wanted = options.subdomain();
		log(`Choosing the workers.dev name ${wanted}`);
		sub = await api.call<{ subdomain: string }>("PUT", "/workers/subdomain", { subdomain: wanted });
		await api.call("POST", `/workers/scripts/${name}/subdomain`, { enabled: true, previews_enabled: false });
	}
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
		await new Promise((r) => setTimeout(r, options.retryMs ?? 2_000));
	}
	throw new Error(`Deployed, but ${url}/v1/health did not answer yet.`);
}
