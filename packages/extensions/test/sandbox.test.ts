import { spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { describe, expect, test } from "vitest";
import { confine, sandboxRoots, sandboxShims, seatbeltProfile } from "../src/sandbox.js";

describe.skipIf(process.platform !== "darwin")("piopio-sandbox", () => {
	// Stand-ins for the real tools, after the wrappers on PATH: they print what they were given.
	function run(command: string) {
		const project = realpathSync(mkdtempSync(join(tmpdir(), "piopio-sandbox-unit-")));
		const bin = join(project, "bin");
		mkdirSync(bin);
		for (const tool of ["swift", "xcodebuild"]) {
			writeFileSync(join(bin, tool), `#!/bin/sh\necho "${tool} $* XBS=\${XBS_DISABLE_SANDBOXED_BUILDS:-}"\n`);
			chmodSync(join(bin, tool), 0o755);
		}
		const line = confine(command, seatbeltProfile(sandboxRoots(project)), "/bin/sh", sandboxShims());
		return spawnSync("/bin/sh", ["-c", line], { cwd: project, encoding: "utf8", env: { ...process.env, PATH: `${bin}:/usr/bin:/bin` } });
	}

	test("swift and xcodebuild run with their own sandbox off, since macOS refuses one inside Piopio's", () => {
		const r = run("swift build -c release; swift --version; xcodebuild -scheme App build");
		expect(r.stdout.trim().split("\n")).toEqual([
			"swift build --disable-sandbox -c release XBS=",
			"swift --version XBS=",
			"xcodebuild -IDEPackageSupportDisableManifestSandbox=YES -IDEPackageSupportDisablePluginExecutionSandbox=YES -scheme App build XBS=1",
		]);
	});

	test("a sandbox inside the sandbox is refused, which is why the wrappers exist", () => {
		const r = run("/usr/bin/sandbox-exec -p '(version 1)(allow default)' /usr/bin/true");
		expect(r.status).not.toBe(0);
		expect(r.stderr).toContain("sandbox_apply: Operation not permitted");
	});
});
