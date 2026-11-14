import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { Client } from "@modelcontextprotocol/sdk/client/index.js";
import { StreamableHTTPClientTransport } from "@modelcontextprotocol/sdk/client/streamableHttp.js";
import { afterEach, describe, expect, it } from "vitest";
import { BROWSER_SERVER, BrowserServer, chromium, playwrightCli } from "../src/browser.js";
import { McpConfig } from "../src/mcp.js";
import { serversSection } from "../src/tools/mcp-chat.js";

const dirs: string[] = [];
const temp = () => {
	const dir = mkdtempSync(join(tmpdir(), "piopio-browser-"));
	dirs.push(dir);
	return dir;
};
afterEach(() => {
	for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

const mkdirp = (dir: string) => (mkdirSync(dir, { recursive: true }), dir);
const mcpJson = (agentDir: string) => JSON.parse(readFileSync(join(agentDir, "mcp.json"), "utf8")) as { mcpServers: Record<string, Record<string, unknown>> };

describe("Piopio's browser (docs/spec/22 §13)", () => {
	it("drives Chrome, else Edge, else Brave or Chromium by path", () => {
		const has = (...paths: string[]) => (p: string) => paths.includes(p);
		expect(chromium(has("/Applications/Google Chrome.app", "/Applications/Microsoft Edge.app"), "/Users/x")).toEqual(["--browser", "chrome"]);
		expect(chromium(has("/Users/x/Applications/Google Chrome.app"), "/Users/x")).toEqual(["--browser", "chrome"]);
		expect(chromium(has("/Applications/Microsoft Edge.app"), "/Users/x")).toEqual(["--browser", "msedge"]);
		expect(chromium(has("/Applications/Brave Browser.app"), "/Users/x")).toEqual(["--executable-path", "/Applications/Brave Browser.app/Contents/MacOS/Brave Browser"]);
		expect(chromium(has(), "/Users/x")).toEqual(["--browser", "chrome"]);
	});

	it("is added to mcp.json once, deferred, with run_code_unsafe off; deleting it keeps it deleted", async () => {
		const home = temp();
		const agentDir = temp();
		const mcp = new McpConfig(agentDir);
		const browser = new BrowserServer(home, mcp);
		expect(await browser.seed()).toBe(true);
		const entry = mcpJson(agentDir).mcpServers[BROWSER_SERVER]!;
		expect(entry.url).toMatch(/^http:\/\/127\.0\.0\.1:\d+\/mcp$/);
		expect(entry.exposure).toBe("deferred");
		expect(entry.toolExposure).toMatchObject({ browser_run_code_unsafe: "hidden", browser_navigate: "direct", browser_snapshot: "direct", browser_find: "direct", browser_click: "direct" });
		expect((entry.toolExposure as Record<string, string>).browser_drag).toBeUndefined();
		expect(entry.description).toContain("Chrome");
		mcp.remove("global", undefined, BROWSER_SERVER);
		expect(await new BrowserServer(home, mcp).seed()).toBe(false);
		expect(mcpJson(agentDir).mcpServers[BROWSER_SERVER]).toBeUndefined();
	});

	it("brings an entry seeded by an older Piopio up to date, keeping the user's per-tool changes", async () => {
		const home = temp();
		const agentDir = temp();
		const mcp = new McpConfig(agentDir);
		mcp.seedGlobal(BROWSER_SERVER, { url: "http://127.0.0.1:41234/mcp", description: "old", exposure: "deferred", toolExposure: { browser_run_code_unsafe: "hidden", browser_click: "hidden" } });
		writeFileSync(join(mkdirp(join(home, "browser")), "state.json"), JSON.stringify({ seeded: true, port: 41234 }));
		expect(await new BrowserServer(home, mcp).seed()).toBe(false);
		const entry = mcpJson(agentDir).mcpServers[BROWSER_SERVER]!;
		expect(entry.description).toContain("returns only the URL and title");
		expect(entry.toolExposure).toMatchObject({ browser_navigate: "direct", browser_click: "hidden", browser_run_code_unsafe: "hidden" });
		expect(JSON.parse(readFileSync(join(home, "browser", "state.json"), "utf8"))).toMatchObject({ version: 2 });
	});

	it("leaves a `browser` the user already has alone, and doesn't run for it", async () => {
		const home = temp();
		const agentDir = temp();
		const mcp = new McpConfig(agentDir);
		mcp.add("global", undefined, BROWSER_SERVER, { command: "my-browser" });
		const browser = new BrowserServer(home, mcp);
		expect(await browser.seed()).toBe(false);
		expect(mcpJson(agentDir).mcpServers[BROWSER_SERVER]).toEqual({ command: "my-browser" });
		await browser.sync();
		expect((browser as unknown as { child?: unknown }).child).toBeUndefined();
	});

	it("chats name their deferred MCP servers in the prompt", () => {
		const text = serversSection([{ name: "browser", description: "Piopio's  browser:\n a real Chrome" }, { name: "notes" }]);
		expect(text).toContain("tool_search");
		expect(text).toContain("- browser: Piopio's browser: a real Chrome");
		expect(text).toContain("- notes");
	});

	it("runs Playwright MCP on its port, follows Settings turning it off, and stops", async () => {
		expect(playwrightCli()).toBeTruthy();
		const home = temp();
		const agentDir = temp();
		const mcp = new McpConfig(agentDir);
		const browser = new BrowserServer(home, mcp);
		await browser.seed();
		await browser.sync();
		const url = String(mcpJson(agentDir).mcpServers[BROWSER_SERVER]!.url);
		const client = new Client({ name: "test", version: "1" });
		let connected = false;
		for (let i = 0; i < 40 && !connected; i++) {
			try {
				await client.connect(new StreamableHTTPClientTransport(new URL(url)));
				connected = true;
			} catch {
				await new Promise((r) => setTimeout(r, 250));
			}
		}
		expect(connected).toBe(true);
		const { tools } = await client.listTools();
		expect(tools.map((t) => t.name)).toEqual(expect.arrayContaining(["browser_navigate", "browser_snapshot", "browser_find", "browser_click", "browser_type", "browser_take_screenshot"]));
		await client.close();
		mcp.setEnabled("global", undefined, BROWSER_SERVER, false);
		await browser.sync();
		expect((browser as unknown as { child?: unknown }).child).toBeUndefined();
		await browser.stop();
	}, 30_000);
});
