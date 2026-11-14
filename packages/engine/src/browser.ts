/**
 * Piopio's browser (docs/spec/22-browser.md §13): Playwright MCP as one local HTTP server the engine owns, driving a
 * visible Chrome with a profile of its own, so what you sign in to there stays signed in. It's seeded once into pi's
 * global mcp.json as `browser`, so Settings › MCP servers, chats, Build and the pi CLI reach it the usual way; turn it
 * off or delete it there and Piopio leaves it alone (it isn't added back).
 *
 * One server, one browser: a persistent profile can only be open in one Chrome at a time, and every client (each chat,
 * each Build session) shares that Chrome's tabs.
 */
import { spawn, type ChildProcess } from "node:child_process";
import { createWriteStream, existsSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { connect, createServer } from "node:net";
import { homedir } from "node:os";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import type { McpConfig, RawServer } from "./mcp.js";

export const BROWSER_SERVER = "browser";

const DESCRIPTION =
	"Piopio's browser: a real Chrome window the user can see, with its own sign-ins. Use it for pages that need scripts, " +
	"a sign-in or clicking and typing; read public pages with web_fetch instead. Opening a page or acting on it returns " +
	"only the URL and title: read the page with browser_find (to locate something) or browser_snapshot (with a depth, " +
	"pages can be large). Stop and ask the user before anything that sends, buys, books, deletes, publishes or shares " +
	"personal details, and let them type passwords and payment details themselves.";

/**
 * What a browsing task needs, declared to the model from the start: finding them with tool_search took two searches
 * in the first real run, and each search changed the tools and lost the prompt cache. The rest stay deferred.
 */
const DIRECT_TOOLS = [
	"browser_navigate", "browser_navigate_back", "browser_snapshot", "browser_find", "browser_click", "browser_type",
	"browser_fill_form", "browser_select_option", "browser_press_key", "browser_take_screenshot", "browser_tabs",
	"browser_wait_for", "browser_handle_dialog", "browser_close",
];

/** Tools that stay off unless the user turns them on: it runs code with Playwright's own access to this Mac. */
const HIDDEN_TOOLS = ["browser_run_code_unsafe"];

const toolExposure = () => ({ ...Object.fromEntries(DIRECT_TOOLS.map((t) => [t, "direct"])), ...Object.fromEntries(HIDDEN_TOOLS.map((t) => [t, "hidden"])) });

/** Bumped when the seeded entry changes, so installs seeded earlier get the change (version 2: direct tools). */
const SEED_VERSION = 2;

type State = { seeded?: boolean; port?: number; version?: number };

export class BrowserServer {
	private child?: ChildProcess;
	private stopping = false;
	private restarts: number[] = [];

	constructor(
		private readonly home: string,
		private readonly mcp: McpConfig,
		private readonly log: (line: string) => void = () => {},
	) {}

	private get dir() {
		return join(this.home, "browser");
	}

	private state(): State {
		try {
			return JSON.parse(readFileSync(join(this.dir, "state.json"), "utf8")) as State;
		} catch {
			return {};
		}
	}

	private save(state: State): void {
		mkdirSync(this.dir, { recursive: true });
		writeFileSync(join(this.dir, "state.json"), `${JSON.stringify(state, null, "\t")}\n`);
	}

	private url(port: number) {
		return `http://127.0.0.1:${port}/mcp`;
	}

	/** Adds `browser` to mcp.json the first time. True when it did, so the caller can turn it on for chats. */
	async seed(): Promise<boolean> {
		const state = this.state();
		if (state.seeded) {
			if ((state.version ?? 1) < SEED_VERSION) this.upgrade(state);
			return false;
		}
		const port = state.port ?? (await freePort());
		const written = this.mcp.seedGlobal(BROWSER_SERVER, {
			url: this.url(port),
			description: DESCRIPTION,
			// Declared to the model when tool_search finds them (Build), listed by name in chats' prompt.
			exposure: "deferred",
			toolExposure: toolExposure(),
		});
		this.save({ seeded: true, port, version: SEED_VERSION });
		return written;
	}

	/** An entry seeded by an older Piopio and still ours: new description and exposure, keeping per-tool changes made since. */
	private upgrade(state: State): void {
		const entry = this.mcp.globalServers().find((s) => s.name === BROWSER_SERVER)?.server;
		if (entry && state.port && entry.url === this.url(state.port)) {
			this.mcp.patchGlobal(BROWSER_SERVER, { description: DESCRIPTION, toolExposure: { ...toolExposure(), ...entry.toolExposure } });
		}
		this.save({ ...state, version: SEED_VERSION });
	}

	/** Whether mcp.json's `browser` is still ours (its URL is this engine's port) and on. */
	private wanted(state: State): boolean {
		const entry = this.mcp.globalServers().find((s) => s.name === BROWSER_SERVER)?.server;
		return Boolean(state.port && entry && entry.enabled !== false && entry.url === this.url(state.port));
	}

	/** Starts or stops the server to match mcp.json (at launch, and after Settings › MCP servers changes it). */
	async sync(): Promise<void> {
		const state = this.state();
		const wanted = this.wanted(state);
		if (wanted && !this.child) {
			this.stopping = false;
			await this.start(state);
		} else if (!wanted && this.child) {
			await this.stop();
			this.log("Browser: turned off in MCP servers");
		}
	}

	private async start(state: State): Promise<void> {
		let port = state.port!;
		if (!(await portFree(port))) {
			// Something else took the port while Piopio was off: move, and point mcp.json at the new one.
			port = await freePort();
			this.mcp.patchGlobal(BROWSER_SERVER, { url: this.url(port) } satisfies Partial<RawServer>);
			this.save({ ...state, port });
			this.log(`Browser: port ${state.port} was taken; now on ${port}`);
		}
		this.spawn(port);
		// Chats connect as soon as the app opens one: answer only once the server does.
		if (!(await listening(port, 15_000))) this.log(`Browser: the server didn't answer on ${port} in 15s (see browser/server.log)`);
	}

	private spawn(port: number): void {
		const cli = playwrightCli();
		if (!cli) {
			this.log("Browser: Playwright MCP isn't installed with the engine; the browser is off");
			return;
		}
		mkdirSync(this.dir, { recursive: true });
		const args = [
			cli,
			"--port", String(port),
			"--host", "127.0.0.1",
			...chromium(),
			"--user-data-dir", join(this.dir, "profile"),
			"--output-dir", join(this.dir, "output"),
			"--output-max-size", String(50 * 1024 * 1024),
			"--shared-browser-context",
			// Chrome closes after 5 minutes without a browser call (Playwright never does for a visible window by
			// default); the next call opens it again, with the same sign-ins.
			"--idle-timeout", String(5 * 60_000),
			// Actions answer with the page's URL and title; the model asks for the page with browser_snapshot or
			// browser_find (a whole page can be 100k+ tokens, and the file Playwright writes otherwise isn't readable in chats).
			"--snapshot-mode", "none",
			"--codegen", "none",
			// Screenshots and saved files by their full path, which Build's tools and present_files can use.
			"--file-paths", "absolute",
			"--console-level", "warning",
		];
		const logFile = createWriteStream(join(this.dir, "server.log"), { flags: "a" });
		const child = spawn(process.execPath, args, { stdio: ["ignore", "pipe", "pipe"] });
		child.stdout?.pipe(logFile);
		child.stderr?.pipe(logFile);
		this.child = child;
		this.log(`Browser: Playwright MCP on ${this.url(port)}`);
		child.on("exit", (code, signal) => {
			if (this.child === child) this.child = undefined;
			if (this.stopping) return;
			const now = Date.now();
			this.restarts = [...this.restarts.filter((t) => now - t < 60_000), now];
			if (this.restarts.length > 3) {
				this.log(`Browser: the server keeps stopping (${code ?? signal}); it stays off until the engine restarts`);
				return;
			}
			setTimeout(() => !this.stopping && !this.child && this.spawn(port), 2_000).unref();
		});
	}

	async stop(): Promise<void> {
		this.stopping = true;
		const child = this.child;
		if (!child || child.exitCode !== null) return;
		await new Promise<void>((resolve) => {
			const timer = setTimeout(() => (child.kill("SIGKILL"), resolve()), 3_000);
			child.once("exit", () => (clearTimeout(timer), resolve()));
			child.kill("SIGTERM");
		});
	}
}

/** Playwright MCP's cli.js: in node_modules beside the bundled engine, or the package's in development. */
export function playwrightCli(from = dirname(fileURLToPath(import.meta.url))): string | undefined {
	for (let dir = from; dir !== dirname(dir); dir = dirname(dir)) {
		const cli = join(dir, "node_modules", "@playwright", "mcp", "cli.js");
		if (existsSync(cli)) return cli;
	}
	return undefined;
}

/** Which installed Chromium to drive, checked at each start so installing Chrome later just works. */
export function chromium(exists: (path: string) => boolean = existsSync, home = homedir()): string[] {
	const apps = (name: string) => [join("/Applications", name), join(home, "Applications", name)];
	if (apps("Google Chrome.app").some(exists)) return ["--browser", "chrome"];
	if (apps("Microsoft Edge.app").some(exists)) return ["--browser", "msedge"];
	for (const [app, binary] of [["Brave Browser.app", "Brave Browser"], ["Chromium.app", "Chromium"]] as const) {
		const found = apps(app).find(exists);
		if (found) return ["--executable-path", join(found, "Contents", "MacOS", binary)];
	}
	// None found: Playwright's own error says Chrome is missing when the model first opens a page.
	return ["--browser", "chrome"];
}

function freePort(): Promise<number> {
	return new Promise((resolve, reject) => {
		const server = createServer();
		server.once("error", reject);
		server.listen(0, "127.0.0.1", () => {
			const { port } = server.address() as { port: number };
			server.close(() => resolve(port));
		});
	});
}

/** Waits until something accepts connections on the port. */
async function listening(port: number, timeoutMs: number): Promise<boolean> {
	for (const started = Date.now(); Date.now() - started < timeoutMs; ) {
		const ok = await new Promise<boolean>((resolve) => {
			const socket = connect(port, "127.0.0.1");
			socket.once("connect", () => (socket.destroy(), resolve(true)));
			socket.once("error", () => resolve(false));
		});
		if (ok) return true;
		await new Promise((r) => setTimeout(r, 100));
	}
	return false;
}

function portFree(port: number): Promise<boolean> {
	return new Promise((resolve) => {
		const server = createServer();
		server.once("error", () => resolve(false));
		server.listen(port, "127.0.0.1", () => server.close(() => resolve(true)));
	});
}
