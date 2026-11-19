/**
 * Deploys `piopio-cloud` by hand with the Cloudflare REST API and an API token. The app does the same from
 * Settings › This Mac & cloud with the steps in packages/engine/src/cloud-deploy.ts, and ships the bundle prebuilt.
 * Wrangler is only the bundler here (`--dry-run --outdir`).
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
import { readFileSync } from "node:fs";
import { join } from "node:path";
import { fileURLToPath } from "node:url";
import { CloudflareApi, deploy, pendingMigrations, readBundle, scriptMetadata, SECRETS, VARS, type DeployOptions, type WranglerConfig } from "../../engine/src/cloud-deploy.ts";

// The library lives in the engine, which deploys from Settings; this script is the same steps by hand.
export { CloudflareApi, deploy, pendingMigrations, readBundle, scriptMetadata, type WranglerConfig } from "../../engine/src/cloud-deploy.ts";

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
