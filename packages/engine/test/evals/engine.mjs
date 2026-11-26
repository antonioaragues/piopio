// The engine for one scenario: `piopio-engine` (packages/engine/dist/main.js) started as the app starts it, with a
// data folder of its own, and a client that talks to it over its socket as test/client.ts does. Keys come from the
// environment (PIOPIO_ALLOW_ENV_SECRETS=1); the coding agents are the CLIs installed on this Mac, signed in as you.
import { spawn } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, existsSync } from "node:fs";
import { createConnection } from "node:net";
import { tmpdir } from "node:os";
import { join } from "node:path";

export class Client {
	constructor(socket) {
		this.socket = socket;
		this.buf = "";
		this.id = 1;
		this.waiters = new Map();
		/** Answers `app.tool` (the browser stand-in). */
		this.appTool = undefined;
		socket.setEncoding("utf8");
		socket.on("data", (d) => {
			this.buf += d;
			let i;
			while ((i = this.buf.indexOf("\n")) !== -1) {
				const line = this.buf.slice(0, i);
				this.buf = this.buf.slice(i + 1);
				if (line) this.onMessage(JSON.parse(line));
			}
		});
	}

	static connect(path) {
		return new Promise((resolve, reject) => {
			const s = createConnection(path, () => resolve(new Client(s)));
			s.once("error", reject);
		});
	}

	call(method, params = {}) {
		const id = this.id++;
		this.socket.write(`${JSON.stringify({ jsonrpc: "2.0", id, method, params })}\n`);
		return new Promise((resolve, reject) => this.waiters.set(id, { resolve, reject, method }));
	}

	reply(id, result) {
		this.socket.write(`${JSON.stringify({ jsonrpc: "2.0", id, result })}\n`);
	}

	onMessage(m) {
		if (m.method === "secrets.get") return this.reply(m.id, { value: null }); // the engine falls back to the environment
		if (m.method === "secrets.set" || m.method === "secrets.delete") return this.reply(m.id, {});
		if (m.method === "app.tool") {
			Promise.resolve()
				.then(() => (this.appTool ? this.appTool(m.params) : { ok: false, output: "Not available in the eval runner." }))
				.then(
					(result) => this.reply(m.id, result),
					(error) => this.socket.write(`${JSON.stringify({ jsonrpc: "2.0", id: m.id, error: { code: -32000, message: error.message } })}\n`),
				);
			return;
		}
		if (m.method && m.id !== undefined) return this.socket.write(`${JSON.stringify({ jsonrpc: "2.0", id: m.id, error: { code: -32601, message: `${m.method} isn't served by the eval runner` } })}\n`);
		if ("id" in m && this.waiters.has(m.id)) {
			const w = this.waiters.get(m.id);
			this.waiters.delete(m.id);
			if (m.error) w.reject(Object.assign(new Error(`${w.method}: ${m.error.message}`), { data: m.error.data }));
			else w.resolve(m.result);
		}
	}

	close() {
		this.socket.end();
	}
}

/** Starts an engine in a fresh data folder and connects to it as the app would (serving `app.tool` and `browser`). */
export async function startEngine(root, { env = {}, log } = {}) {
	const home = mkdtempSync(join(tmpdir(), "piopio-eval-"));
	mkdirSync(join(home, "logs"), { recursive: true });
	const stderr = [];
	const proc = spawn(process.execPath, [join(root, "packages/engine/dist/main.js")], {
		env: {
			...process.env,
			PIOPIO_HOME: home,
			PIOPIO_ALLOW_ENV_SECRETS: "1",
			PIOPIO_PI_SESSION_DIR: join(home, "pi-sessions"),
			PIOPIO_PI_AGENT_DIR: join(home, "pi-agent"),
			PIOPIO_AGENTS_DIR: join(home, "Agents"),
			...env,
		},
		stdio: ["ignore", "ignore", "pipe"],
	});
	proc.stderr.setEncoding("utf8");
	proc.stderr.on("data", (d) => {
		stderr.push(d);
		log?.(d);
	});
	const socket = join(home, "engine.sock");
	const token = join(home, "engine.token");
	const end = Date.now() + 30_000;
	while (!(existsSync(socket) && existsSync(token))) {
		if (proc.exitCode !== null) throw new Error(`The engine exited: ${stderr.join("").slice(-1000)}`);
		if (Date.now() > end) throw new Error(`The engine didn't start: ${stderr.join("").slice(-1000)}`);
		await new Promise((r) => setTimeout(r, 100));
	}
	const client = await Client.connect(socket);
	await client.call("engine.hello", { token: readFileSync(token, "utf8").trim(), client: "piopio-evals", protocolVersion: "1.0", services: ["app.tool", "browser", "secrets.set"] });
	return {
		home,
		client,
		stderr,
		async stop() {
			client.close();
			proc.kill("SIGTERM");
			await new Promise((r) => {
				const t = setTimeout(() => {
					proc.kill("SIGKILL");
					r();
				}, 10_000);
				proc.once("exit", () => {
					clearTimeout(t);
					r();
				});
			});
			rmSync(home, { recursive: true, force: true });
		},
	};
}
