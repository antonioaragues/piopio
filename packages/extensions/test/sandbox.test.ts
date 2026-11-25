import { spawn, spawnSync } from "node:child_process";
import { createServer } from "node:http";
import { chmodSync, existsSync, mkdirSync, mkdtempSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ToolDefinition } from "@earendil-works/pi-coding-agent";
import { describe, expect, test } from "vitest";
import { confine, networkHint, proxyEnv, sandboxExtension, sandboxHidden, sandboxHint, sandboxProfile, sandboxRoots, sandboxShims, seatbeltProfile } from "../src/sandbox.js";

// The wrappers go in Piopio's data folder: a scratch one here, never the user's.
process.env.PIOPIO_HOME = realpathSync(mkdtempSync(join(tmpdir(), "pio-home-")));

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

	test("the wrappers sit in Piopio's data folder, where confined commands can run them but not plant others", () => {
		const shims = sandboxShims()!;
		expect(shims.startsWith(`${process.env.PIOPIO_HOME}/`)).toBe(true);
		const r = run(`ls ${shims} && echo fake > ${shims}/git`);
		expect(r.stdout.trim().split("\n")).toEqual(["swift", "xcodebuild"]);
		expect(r.stderr).toContain("Operation not permitted");
		expect(existsSync(join(shims, "git"))).toBe(false);
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
			// Tools that resolve the working folder stat the folders above it, in Piopio's data.
			expect(sh(`${process.execPath} -e 'console.log(require("fs").realpathSync("."))'`).stdout.trim()).toBe(chat);
			expect(sh(`ls ${piopio}`).stderr).toContain("Operation not permitted");
			expect(sh(`echo x > ${join(piopio, "engine.token")}`).stderr).toContain("Operation not permitted");
			const connect = `${process.execPath} -e 'require("net").connect("e.sock").on("data", (d) => console.log(String(d))).on("error", (e) => console.log(e.code))'`;
			expect(spawnSync("/bin/sh", ["-c", connect], { cwd: piopio, encoding: "utf8" }).stdout.trim()).toBe("hi");
			expect(sh(connect, piopio).stdout.trim()).toBe("EPERM");
		} finally {
			server.kill();
		}
	});

	test("credentials stay out of reach: plain-text credential files, SSH private keys by their contents, the Keychain tool", () => {
		const base = realpathSync(mkdtempSync(join(tmpdir(), "pio-cred-")));
		const home = join(base, "home");
		const project = join(base, "project");
		mkdirSync(join(home, ".ssh"), { recursive: true });
		mkdirSync(project);
		writeFileSync(join(home, ".netrc"), "machine github.com password hunter2\n");
		writeFileSync(join(home, ".ssh", "work_key"), "-----BEGIN OPENSSH PRIVATE KEY-----\nabc\n");
		writeFileSync(join(home, ".ssh", "work_key.pub"), "ssh-ed25519 AAAA me\n");
		writeFileSync(join(home, ".ssh", "config"), "Host x\n");
		const hidden = sandboxHidden({ home, piopioHome: join(base, "P") });
		expect(hidden).toContain(join(home, ".netrc"));
		expect(hidden).toContain(join(home, ".ssh", "work_key"));
		expect(hidden).not.toContain(join(home, ".ssh", "work_key.pub"));
		const profile = seatbeltProfile(sandboxRoots(project, { home }), hidden);
		const sh = (command: string) => spawnSync("/bin/sh", ["-c", confine(command, profile, "/bin/sh")], { cwd: project, encoding: "utf8" });
		expect(sh(`cat ${join(home, ".netrc")}`).stderr).toContain("Operation not permitted");
		expect(sh(`cat ${join(home, ".ssh", "work_key")}`).stderr).toContain("Operation not permitted");
		expect(sh(`cat ${join(home, ".ssh", "work_key.pub")} ${join(home, ".ssh", "config")}`).stdout).toBe("ssh-ed25519 AAAA me\nHost x\n");
		expect(sh("/usr/bin/security list-keychains").stderr).toContain("Operation not permitted");
	});

	test("every credential paths.ts marks hidden is unreadable; the ones tools need stay readable", () => {
		const base = realpathSync(mkdtempSync(join(tmpdir(), "pio-cred2-")));
		const home = join(base, "home");
		const project = join(base, "project");
		mkdirSync(project);
		const hiddenFiles = [".config/gh/hosts.yml", ".config/gcloud/credentials.db", ".claude/.credentials.json", ".cargo/credentials.toml", ".vault-token"];
		const readable = [".npmrc", ".docker/config.json", ".kube/config"];
		for (const f of [...hiddenFiles, ...readable]) {
			mkdirSync(join(home, f, ".."), { recursive: true });
			writeFileSync(join(home, f), "x\n");
		}
		const sh = (command: string) => spawnSync("/bin/sh", ["-c", confine(command, sandboxProfile(project, { home, piopioHome: join(base, "P") }), "/bin/sh")], { cwd: project, encoding: "utf8" });
		for (const f of hiddenFiles) expect(sh(`cat ${join(home, f)}`).stderr, f).toContain("Operation not permitted");
		for (const f of readable) expect(sh(`cat ${join(home, f)}`).stdout, f).toBe("x\n");
	});

	// Re-audit 2026-11-25 (V3): a confined command could plant code that pi, Claude Code or git run later, unconfined.
	test("the project's agent setup can't be written, created, renamed away or replaced; the rest of the project can", () => {
		const project = realpathSync(mkdtempSync(join(tmpdir(), "pio-control-")));
		spawnSync("git", ["init", "-q"], { cwd: project });
		mkdirSync(join(project, ".pi", "skills"), { recursive: true });
		mkdirSync(join(project, ".claude"));
		const sh = (command: string) => spawnSync("/bin/sh", ["-c", confine(command, sandboxProfile(project), "/bin/sh")], { cwd: project, encoding: "utf8" });
		for (const command of ["mkdir .pi/extensions", "echo x > .pi/settings.json", "echo x > .claude/settings.json", "echo x > .claude/settings.local.json", "echo x > .mcp.json", "echo x > .git/hooks/post-checkout", "mv .pi .pi-old", "rm -rf .claude", "ln -s /tmp .pi/extensions"]) {
			const r = sh(command);
			expect(r.status, command).not.toBe(0);
			expect(r.stderr, command).toContain("Operation not permitted");
		}
		expect(existsSync(join(project, ".pi", "extensions"))).toBe(false);
		expect(existsSync(join(project, ".pi", "skills"))).toBe(true);
		expect(sh("echo ok > .pi/skills/note.md && mkdir -p src && echo x > src/a.ts && git add -A && git -c user.email=a@b -c user.name=a commit -qm x && echo done").stdout.trim()).toBe("done");
	});
});

test("a confined command's failure says what stopped it: signed out of GitHub, a write outside, a nested sandbox", () => {
	expect(sandboxHint("To get started with GitHub CLI, please run:  gh auth login")).toMatch(/signed out.*outside_project: true/s);
	expect(sandboxHint("fatal: could not read Username for 'https://github.com': terminal prompts disabled")).toMatch(/signed out/);
	expect(sandboxHint("touch: /etc/x: Operation not permitted")).toMatch(/stopped a write outside the project/);
	expect(sandboxHint("sandbox_apply: Operation not permitted")).toMatch(/its own macOS sandbox/);
	expect(sandboxHint("Error: tests failed")).toBeUndefined();
});

describe.skipIf(process.platform !== "darwin")("a filtered network (docs/spec/39)", () => {
	test("nothing outside this Mac answers, a server on it does, and tools are pointed at the proxy", async () => {
		const server = createServer((_req, res) => res.end("local"));
		await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
		const port = (server.address() as { port: number }).port;
		try {
			const project = realpathSync(mkdtempSync(join(tmpdir(), "pio-net-")));
			const profile = seatbeltProfile(sandboxRoots(project), undefined, undefined, true);
			const sh = (command: string) =>
				new Promise<string>((resolve) => {
					const child = spawn("/bin/sh", ["-c", confine(command, profile, "/bin/sh", undefined, proxyEnv(4321))], { cwd: project });
					let out = "";
					child.stdout.on("data", (d) => (out += d));
					child.stderr.on("data", (d) => (out += d));
					child.on("close", () => resolve(out.trim()));
				});
			expect(await sh(`curl -s --noproxy '*' http://127.0.0.1:${port}/`)).toBe("local");
			expect(await sh("curl -sS --noproxy '*' --max-time 5 -o /dev/null http://1.1.1.1/; echo exit=$?")).toMatch(/exit=7/);
			expect(await sh("echo $HTTPS_PROXY $NO_PROXY $NODE_USE_ENV_PROXY")).toBe("http://127.0.0.1:4321 localhost,127.0.0.1,::1 1");
			// No name lookups (re-audit V5: DNS carried data past the filter), but "localhost" still resolves.
			const lookup = (name: string) => sh(`${process.execPath} -e 'require("dns").lookup("${name}", (e, a) => console.log(e ? e.code : "ok"))'`);
			expect(await lookup("example.com")).toBe("ENOTFOUND");
			expect(await lookup("localhost")).toBe("ok");
			expect(await sh(`curl -s --noproxy '*' http://localhost:${port}/`)).toBe("local");
			// Not filtered: the profile has no network rule.
			expect(seatbeltProfile(sandboxRoots(project))).not.toContain("network-outbound (remote ip");
		} finally {
			server.close();
		}
	});

	test("the note after a refused site names it and says not to look for another way", () => {
		expect(networkHint(["evil.example", "x.example:22"])).toMatch(/kept this command from reaching evil\.example, x\.example:22\..*Don't look for another way/s);
	});
});
