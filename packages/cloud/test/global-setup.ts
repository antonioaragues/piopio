/** Builds the Worker bundle once (the same bundle `scripts/deploy.ts` uploads). */
import { execFileSync } from "node:child_process";
import { existsSync } from "node:fs";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("..", import.meta.url));

export default function setup() {
	// The bundle inlines @piopio/protocol from its dist/.
	if (!existsSync(new URL("../../protocol/dist/index.js", import.meta.url))) {
		execFileSync(process.execPath, [fileURLToPath(new URL("../../../node_modules/typescript/bin/tsc", import.meta.url)), "-p", "../protocol/tsconfig.json"], { cwd: root, stdio: "inherit" });
	}
	// …and @piopio/runtime (the agent) from its dist/ (spike S7).
	execFileSync(process.execPath, [fileURLToPath(new URL("../../../node_modules/typescript/bin/tsc", import.meta.url)), "-p", "../runtime/tsconfig.json"], { cwd: root, stdio: "inherit" });
	execFileSync(fileURLToPath(new URL("../node_modules/.bin/wrangler", import.meta.url)), ["deploy", "--dry-run", "--outdir", "dist"], {
		cwd: root,
		stdio: ["ignore", "ignore", "inherit"],
		env: { ...process.env, WRANGLER_SEND_METRICS: "false" },
	});
}
