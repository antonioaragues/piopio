#!/usr/bin/env node
// Bundles the engine for the app (docs/spec/02-architecture §4.1): one ESM file plus the few assets
// pi reads from disk at runtime.
//
//   node scripts/bundle.mjs <outDir> [version]
//
//   <outDir>/package.json        {"type": "module"}, so node-worker.js loads as ESM
//   <outDir>/main.js             the engine (run with the bundled node)
//   <outDir>/node-worker.js      pi-durable's Photon image worker (resolved next to main.js)
//   <outDir>/codemode-worker.js  pi's codemode script worker (resolved next to main.js)
//   <outDir>/pi/                 pi-coding-agent's package.json, README, docs and examples (PI_PACKAGE_DIR)
//   <outDir>/node_modules/…      the .wasm files pi resolves with require.resolve
import { build } from "esbuild";
import { cpSync, existsSync, mkdirSync, realpathSync, rmSync, writeFileSync } from "node:fs";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const [outArg, version = "dev"] = process.argv.slice(2);
if (!outArg) {
	console.error("usage: node scripts/bundle.mjs <outDir> [version]");
	process.exit(2);
}
const out = resolve(outArg);
const engineDir = resolve(dirname(fileURLToPath(import.meta.url)), "..");
// Node's lookup, by folder: these packages export only ESM entries, so require.resolve can't find their roots.
const packageRoot = (name, from = engineDir) => {
	for (let dir = from; dir !== dirname(dir); dir = dirname(dir)) {
		const candidate = join(dir, "node_modules", name);
		if (existsSync(join(candidate, "package.json"))) return realpathSync(candidate);
	}
	throw new Error(`${name} not found from ${from}`);
};

const piCodingAgent = packageRoot("@earendil-works/pi-coding-agent");
const piDurable = packageRoot("@earendil-works/pi-durable");
const photon = packageRoot("@silvia-odwyer/photon", piDurable);
const quickjs = packageRoot("quickjs-wasi", piCodingAgent);

rmSync(out, { recursive: true, force: true });
mkdirSync(out, { recursive: true });

// Runs before any bundled module: CommonJS deps need `require`, and pi looks for its package folder
// (docs, version, piConfig) at PI_PACKAGE_DIR.
const banner = [
	`import { createRequire as __piopioCreateRequire } from "node:module";`,
	`import { fileURLToPath as __piopioFileURLToPath } from "node:url";`,
	`const require = __piopioCreateRequire(import.meta.url);`,
	`process.env.PI_PACKAGE_DIR ??= __piopioFileURLToPath(new URL("./pi", import.meta.url));`,
].join("\n");

const common = {
	bundle: true,
	platform: "node",
	format: "esm",
	target: "node22.19",
	banner: { js: banner },
	// pi's bundled-Node mode: user extensions get pi's packages as virtual modules instead of
	// resolving them from a node_modules folder that the app doesn't ship.
	define: { PI_BUNDLED_NODE: "true", PIOPIO_ENGINE_VERSION: JSON.stringify(version) },
	legalComments: "linked",
	logLevel: "warning",
};
await build({ ...common, entryPoints: { main: join(engineDir, "dist/main.js") }, outdir: out });
await build({ ...common, entryPoints: { "node-worker": join(piDurable, "dist/images/node-worker.js") }, outdir: out, define: {} });
// pi's codemode runs scripts in a worker it loads from a data: URL in bundled-Node mode (MCP tools are reached
// through it): self-contained, so no banner (it uses import.meta, which a data: URL can't resolve against).
await build({ ...common, banner: {}, entryPoints: { "codemode-worker": join(packageRoot("@earendil-works/pi-codemode", piCodingAgent), "dist/runtime/worker.js") }, outdir: out, define: {} });

writeFileSync(join(out, "package.json"), `${JSON.stringify({ name: "piopio-engine", version, private: true, type: "module" }, null, "\t")}\n`);
for (const item of ["package.json", "README.md", "docs", "examples"]) cpSync(join(piCodingAgent, item), join(out, "pi", item), { recursive: true });
for (const [root, files] of [
	[photon, ["package.json", "photon_rs_bg.wasm"]],
	[quickjs, ["package.json", "quickjs.wasm"]],
]) {
	const target = join(out, "node_modules", root.slice(root.lastIndexOf("node_modules/") + "node_modules/".length));
	for (const file of files) cpSync(join(root, file), join(target, file));
}
console.log(out);
