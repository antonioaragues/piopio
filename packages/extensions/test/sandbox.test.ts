import { spawn, spawnSync } from "node:child_process";
import { chmodSync, mkdirSync, mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ToolDefinition } from "@earendil-works/pi-coding-agent";
import { describe, expect, test } from "vitest";
import { confine, sandboxExtension, sandboxHidden, sandboxRoots, sandboxShims, seatbeltProfile } from "../src/sandbox.js";

test("bash activity descriptions are optional metadata and do not change execution", async () => {
	let tool: ToolDefinition | undefined;
	sandboxExtension({ enabled: () => false })({
		on() {},
		registerTool(definition: ToolDefinition) { tool = definition; },
	} as never);
	expect(tool!.parameters.properties.description.type).toBe("string");
	expect(tool!.parameters.required).not.toContain("description");
	for (const description of [undefined, "Checking the project", "$(printf unexpected)"]) {
		const result = await tool!.execute("label-test", { command: "printf label-test", ...(description ? { description } : {}) }, undefined, undefined, undefined as never);
		expect(result.content).toEqual([{ type: "text", text: "label-test" }]);
	}
});

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

	test("Piopio's data and sign-in files can't be read or connected to, but a chat's folder inside it can", async () => {
		const base = realpathSync(mkdtempSync(join(tmpdir(), "pio-h-")));
		const piopio = join(base, "P");
		const home = join(base, "home");
		const chat = join(piopio, "scratch", "c1");
		mkdirSync(chat, { recursive: true });
		mkdirSync(join(home, ".aws"), { recursive: true });
		writeFileSync(join(piopio, "engine.token"), "secret\n");
		writeFileSync(join(home, ".aws", "credentials"), "key\n");
		writeFileSync(join(chat, "notes.txt"), "mine\n");
		const hidden = sandboxHidden({ home, piopioHome: piopio });
		const profile = seatbeltProfile(sandboxRoots(chat, { home }), hidden);
		// A socket the engine would listen on, made by a process outside the sandbox (short relative path: macOS's limit).
		const server = spawn(process.execPath, ["-e", 'require("net").createServer((c) => c.end("hi")).listen("e.sock", () => console.log("up"))'], { cwd: piopio });
		await new Promise((done) => server.stdout.once("data", done));
		try {
			const sh = (command: string, cwd = chat) => spawnSync("/bin/sh", ["-c", confine(command, profile, "/bin/sh")], { cwd, encoding: "utf8" });
			expect(sh(`cat ${join(piopio, "engine.token")}`).stderr).toContain("Operation not permitted");
			expect(sh(`cat ${join(home, ".aws", "credentials")}`).stderr).toContain("Operation not permitted");
			expect(sh("cat notes.txt && echo more > more.txt && cat more.txt").stdout).toBe("mine\nmore\n");
			const connect = `${process.execPath} -e 'require("net").connect("e.sock").on("data", (d) => console.log(String(d))).on("error", (e) => console.log(e.code))'`;
			expect(spawnSync("/bin/sh", ["-c", connect], { cwd: piopio, encoding: "utf8" }).stdout.trim()).toBe("hi");
			expect(sh(connect, piopio).stdout.trim()).toBe("EPERM");
		} finally {
			server.kill();
		}
	});
});
