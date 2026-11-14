import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { Engine } from "../src/server.js";
import { enginePaths } from "../src/paths.js";
import { checkUrl } from "../src/tools/browser-tools.js";

const dirs: string[] = [];
afterEach(() => {
	for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe("the browser's URL check (docs/spec/22 §4.1)", () => {
	it("opens only http(s), and no local or private address", async () => {
		expect(await checkUrl("file:///etc/passwd")).toContain("only http and https");
		expect(await checkUrl("javascript:alert(1)")).toContain("only http and https");
		expect(await checkUrl("http://127.0.0.1:3000/")).toContain("local or private");
		expect(await checkUrl("http://192.168.1.10/")).toContain("local or private");
		expect(await checkUrl("http://localhost/")).toContain("local or private");
		expect(await checkUrl("http://127.0.0.1:3000/", true)).toBeUndefined();
		expect(await checkUrl("not a url")).toContain("Not a URL");
	});
});

describe("the interim Playwright browser (docs/spec/22 §13)", () => {
	it("is taken out on start: its mcp.json entry, its chat switch and its folder; a `browser` of the user's stays", async () => {
		for (const ours of [true, false]) {
			const home = mkdtempSync(join(tmpdir(), "piopio-interim-"));
			dirs.push(home);
			const agentDir = join(home, "pi-agent");
			mkdirSync(join(home, "browser", "profile"), { recursive: true });
			mkdirSync(agentDir, { recursive: true });
			writeFileSync(join(home, "browser", "state.json"), JSON.stringify({ seeded: true, port: 55972, version: 2 }));
			const url = ours ? "http://127.0.0.1:55972/mcp" : "http://127.0.0.1:9999/mcp";
			writeFileSync(join(agentDir, "mcp.json"), JSON.stringify({ mcpServers: { browser: { url }, other: { command: "x" } } }));
			writeFileSync(join(home, "settings.json"), JSON.stringify({ chat: { mcpServers: ["browser", "other"] } }));
			const engine = new Engine({ paths: enginePaths(home), faux: true, piAgentDir: agentDir, piSessionDir: join(home, "s"), agentsDir: join(home, "A"), hooksPort: 0, log: () => {} });
			await engine.listen();
			const servers = JSON.parse(readFileSync(join(agentDir, "mcp.json"), "utf8")).mcpServers;
			expect(Object.keys(servers)).toEqual(ours ? ["other"] : ["browser", "other"]);
			expect(engine.settings.get().chat.mcpServers).toEqual(ours ? ["other"] : ["browser", "other"]);
			expect(existsSync(join(home, "browser"))).toBe(false);
			await engine.stop();
		}
	});
});
