// A stand-in for the Mac app's browser (docs/spec/22), so the evals run without the app: it answers the engine's
// `app.tool` calls for `browser_*` with headless Google Chrome over the DevTools protocol. The page runs its scripts
// for real (the planted 404 and the console error happen as they would in the app's WebKit view), and the preview's
// console and requests come from the app's own recorder script, read from BrowserPreview.swift so the two stay the
// same. What it doesn't do: acting on pages (click, type, select, key), screenshots, scrolling and tabs answer that
// the stand-in can't, and the map lists links, buttons and fields only. The preview scenarios don't need those.
import { spawn } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const CHROME = process.env.PIOPIO_EVAL_CHROME ?? "/Applications/Google Chrome.app/Contents/MacOS/Google Chrome";

/** The app's capture script (BrowserPreview.captureScript), verbatim. */
function captureScript(root) {
	const swift = readFileSync(join(root, "apps/mac/App/Piopio/BrowserPreview.swift"), "utf8");
	const m = swift.match(/static let captureScript = #"""\n([\s\S]*?)\n"""#/);
	if (!m) throw new Error("Couldn't find captureScript in BrowserPreview.swift");
	return m[1];
}

/** The page's interactive elements, as the app's map writes them: `[e1] role "name" @(x,y)`. */
const MAP_SCRIPT = `(() => {
	const els = [...document.querySelectorAll("a[href], button, input, select, textarea, [role=button], [role=link]")];
	let n = 0;
	const lines = [];
	for (const el of els) {
		const r = el.getBoundingClientRect();
		if (!r.width && !r.height) continue;
		const role = el.getAttribute("role") || (el.tagName === "A" ? "link" : el.tagName === "BUTTON" ? "button" : el.tagName === "SELECT" ? "combobox" : "textbox");
		const name = (el.getAttribute("aria-label") || el.innerText || el.value || el.placeholder || "").trim().replace(/\\s+/g, " ").slice(0, 80);
		lines.push("[e" + ++n + "] " + role + ' "' + name + '" @(' + Math.round(r.x + r.width / 2) + "," + Math.round(r.y + r.height / 2) + ")");
	}
	return lines.length ? lines.join("\\n") : "(nothing to click or type into)";
})()`;

export class ChromeStandIn {
	/** Every call and its answer, for the scenarios' checks: { name, args, ok, output, at }. */
	calls = [];

	static async start(root) {
		if (!existsSync(CHROME)) throw new Error(`Google Chrome not found at ${CHROME} (set PIOPIO_EVAL_CHROME)`);
		const profile = mkdtempSync(join(tmpdir(), "piopio-eval-chrome-"));
		const proc = spawn(CHROME, ["--headless=new", "--remote-debugging-port=0", `--user-data-dir=${profile}`, "--no-first-run", "--no-default-browser-check", "--disable-extensions", "about:blank"], { stdio: ["ignore", "ignore", "pipe"] });
		const ws = await new Promise((resolve, reject) => {
			let err = "";
			const t = setTimeout(() => reject(new Error(`Chrome didn't start: ${err.slice(-500)}`)), 20_000);
			proc.stderr.on("data", (d) => {
				err += d;
				const m = err.match(/DevTools listening on (ws:\/\/\S+)/);
				if (m) {
					clearTimeout(t);
					resolve(m[1]);
				}
			});
			proc.once("exit", (code) => reject(new Error(`Chrome exited (${code}): ${err.slice(-500)}`)));
		});
		const b = new ChromeStandIn(proc, profile, captureScript(root));
		await b.connect(ws);
		return b;
	}

	constructor(proc, profile, capture) {
		this.proc = proc;
		this.profile = profile;
		this.capture = capture;
		this.id = 1;
		this.waiters = new Map();
		this.eventListeners = new Set();
		/** One page per conversation (the app keeps a preview tab per project; one conversation per scenario here). */
		this.pages = new Map();
	}

	connect(url) {
		return new Promise((resolve, reject) => {
			this.ws = new WebSocket(url);
			this.ws.onopen = () => resolve();
			this.ws.onerror = (e) => reject(new Error(`CDP: ${e.message ?? "connection failed"}`));
			this.ws.onmessage = (m) => {
				const msg = JSON.parse(m.data);
				if (msg.id && this.waiters.has(msg.id)) {
					const w = this.waiters.get(msg.id);
					this.waiters.delete(msg.id);
					if (msg.error) w.reject(new Error(msg.error.message));
					else w.resolve(msg.result);
				} else if (msg.method) for (const l of this.eventListeners) l(msg);
			};
		});
	}

	send(method, params = {}, sessionId) {
		const id = this.id++;
		this.ws.send(JSON.stringify({ id, method, params, ...(sessionId ? { sessionId } : {}) }));
		return new Promise((resolve, reject) => this.waiters.set(id, { resolve, reject }));
	}

	waitEvent(sessionId, method, timeoutMs) {
		return new Promise((resolve) => {
			const t = setTimeout(() => {
				this.eventListeners.delete(l);
				resolve(undefined);
			}, timeoutMs);
			const l = (msg) => {
				if (msg.sessionId === sessionId && msg.method === method) {
					clearTimeout(t);
					this.eventListeners.delete(l);
					resolve(msg.params);
				}
			};
			this.eventListeners.add(l);
		});
	}

	async page(key) {
		if (this.pages.has(key)) return this.pages.get(key);
		const { targetId } = await this.send("Target.createTarget", { url: "about:blank" });
		const { sessionId } = await this.send("Target.attachToTarget", { targetId, flatten: true });
		await this.send("Page.enable", {}, sessionId);
		await this.send("Runtime.enable", {}, sessionId);
		await this.send("Network.enable", {}, sessionId);
		await this.send("Page.addScriptToEvaluateOnNewDocument", { source: this.capture }, sessionId);
		const page = { sessionId, url: "about:blank", status: undefined };
		this.eventListeners.add((msg) => {
			if (msg.sessionId === sessionId && msg.method === "Network.responseReceived" && msg.params.type === "Document") page.status = msg.params.response.status;
		});
		this.pages.set(key, page);
		return page;
	}

	async eval(page, expression) {
		const r = await this.send("Runtime.evaluate", { expression, awaitPromise: true, returnByValue: true }, page.sessionId);
		if (r.exceptionDetails) throw new Error(r.exceptionDetails.exception?.description ?? r.exceptionDetails.text);
		return r.result.value;
	}

	async header(page) {
		const [title, url] = await this.eval(page, "[document.title, location.href]");
		return `${title} · ${url}`;
	}

	/** Answers one `app.tool` request for a browser tool, as the app would: { ok, output }. */
	async tool(params) {
		const started = Date.now();
		let ok = true;
		let output;
		try {
			output = await this.run(params);
		} catch (error) {
			ok = false;
			output = error.message;
		}
		this.calls.push({ name: params.name, args: params.args, ok, output, ms: Date.now() - started });
		return { ok, output };
	}

	async run({ name, args = {}, ref, preview }) {
		const key = ref?.id ?? "default";
		if (name === "browser_open") {
			const url = new URL(String(args.url));
			const target = `${url.hostname.replace("0.0.0.0", "localhost")}:${url.port || (url.protocol === "https:" ? "443" : "80")}`;
			const local = /^(localhost|127\.0\.0\.1|0\.0\.0\.0|\[?::1\]?)$/.test(url.hostname);
			if (local && !preview?.local.includes(target)) throw new Error(`${target} is a local address: it opens only as the project preview of a Build session.`);
			const page = await this.page(key);
			page.status = undefined;
			const loaded = this.waitEvent(page.sessionId, "Page.loadEventFired", 15_000);
			const nav = await this.send("Page.navigate", { url: url.href }, page.sessionId);
			if (nav.errorText) throw new Error(`The page didn't load: ${nav.errorText}`);
			await loaded;
			// Let the page's own scripts finish their first requests, as the app waits for the page to settle.
			await new Promise((r) => setTimeout(r, 800));
			page.url = url.href;
			let text = await this.header(page);
			if (page.status >= 400) text += `\nThe site answered ${page.status}.`;
			return `${text}\n\n${await this.eval(page, MAP_SCRIPT)}`;
		}
		const page = this.pages.get(key);
		if (!page || page.url === "about:blank") {
			if (["browser_console", "browser_requests", "browser_eval"].includes(name)) throw new Error("The project preview isn't open: start the dev server with bash `background: true` and browser_open the address it prints.");
			throw new Error("No page is open: use browser_open first.");
		}
		const head = await this.header(page);
		switch (name) {
			case "browser_read": {
				const sel = args.selector ? JSON.stringify(args.selector) : "null";
				const text = await this.eval(page, `(() => { const el = ${sel} ? document.querySelector(${sel}) : document.body; return el ? el.innerText : null; })()`);
				if (text === null) throw new Error(`Nothing on the page matches ${args.selector}.`);
				return `${head}\n\n${text}`;
			}
			case "browser_map":
				return `${head}\n\n${await this.eval(page, MAP_SCRIPT)}`;
			case "browser_find": {
				const t = String(args.text ?? "").toLowerCase();
				const lines = (await this.eval(page, MAP_SCRIPT)).split("\n").filter((l) => l.startsWith("[e") && l.toLowerCase().includes(t));
				return lines.length ? lines.join("\n") : `Nothing on the page is named like “${t}”. Try browser_read, or other words.`;
			}
			case "browser_wait": {
				const end = Date.now() + (Number(args.timeout) || 10) * 1000;
				for (;;) {
					const has = await this.eval(page, `document.body.innerText.includes(${JSON.stringify(String(args.text))})`);
					if (has !== Boolean(args.gone)) return `${head}\n${args.gone ? "Gone" : "Found"}: “${args.text}”.`;
					if (Date.now() > end) throw new Error(`“${args.text}” ${args.gone ? "is still there" : "didn't appear"} after ${args.timeout ?? 10} s.`);
					await new Promise((r) => setTimeout(r, 300));
				}
			}
			case "browser_back":
				await this.eval(page, "history.back()");
				await new Promise((r) => setTimeout(r, 800));
				return await this.header(page);
			case "browser_console": {
				const level = args.level ?? "all";
				const entries = await this.eval(page, `(() => { const p = window.__piopioPreview; if (!p) return []; const level = ${JSON.stringify(level)}; const out = p.log.filter((e) => level === "all" || e.level === level || (level === "warn" && e.level === "error")); if (${Boolean(args.clear)}) p.log.length = 0; return out; })()`);
				if (!entries.length) return `${head}\nThe console is empty${level === "all" ? "" : " at that level"}.`;
				return `${head}\n${entries.slice(-150).map((e) => `[${e.level}] ${e.text}`).join("\n")}`;
			}
			case "browser_requests": {
				const entries = await this.eval(page, `(() => { const p = window.__piopioPreview; if (!p) return []; const failed = ${Boolean(args.failed)}, filter = ${JSON.stringify(args.filter ?? "")}; const out = p.reqs.filter((e) => (!failed || e.error || e.status >= 400) && (!filter || e.url.includes(filter))); if (${Boolean(args.clear)}) p.reqs.length = 0; return out; })()`);
				if (!entries.length) return `${head}\nNo requests${args.failed ? " failed" : " yet"}.`;
				return `${head}\n${entries.slice(-150).map((e) => `${e.method} ${e.status ?? e.error ?? "?"} ${e.url} (${e.ms} ms)`).join("\n")}`;
			}
			case "browser_eval": {
				const value = await this.eval(page, `(async () => { const result = await (async () => {\n${args.script}\n})(); return JSON.stringify(result === undefined ? null : result); })()`);
				return `${head}\n${value}`;
			}
			default:
				throw new Error(`The eval runner's browser can't do ${name} (it reads pages; it doesn't act on them).`);
		}
	}

	/** What the last read of the page said (browser_open or browser_read). */
	lastRead() {
		return this.calls.filter((c) => c.ok && (c.name === "browser_read" || c.name === "browser_open")).at(-1)?.output ?? "";
	}

	async stop() {
		try {
			this.ws?.close();
		} catch {}
		this.proc.kill();
		await new Promise((r) => setTimeout(r, 300));
		rmSync(this.profile, { recursive: true, force: true });
	}
}
