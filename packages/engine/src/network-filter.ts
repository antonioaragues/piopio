/**
 * The network filter (docs/spec/39): in a project you haven't trusted yet, a Build session's sandboxed commands reach
 * the internet only through this proxy, on 127.0.0.1 (the sandbox lets them reach nothing else outside this Mac).
 *
 * - HTTPS goes through as a tunnel (CONNECT host:443): nothing is decrypted, the host is all the filter sees. Plain
 *   HTTP is forwarded. Ports 80 and 443 only.
 * - A host passes when it's on the built-in list (package registries, GitHub), matches one of the project's rules
 *   ("example.com", "*.example.com"), or the user allowed it in this session. Any other host waits while the user is
 *   asked, once per host: Allow (this session), Always (a rule of the project) or Deny (refused for the session).
 * - A stopped run refuses what was waiting without deciding: the next command that wants the host asks again.
 * - It keeps a list of what it refused, which the bash tool turns into a note for the agent.
 */
import { createServer, request as httpRequest, type IncomingMessage, type Server, type ServerResponse } from "node:http";
import { connect as tcpConnect, isIP, type Socket } from "node:net";

/** Hosts a project's commands reach without asking: where installs and builds get their packages, and GitHub (reads: commands are signed out of it in the sandbox). */
export const BUILT_IN_HOSTS = [
	// npm, Yarn, pnpm and Bun (npm's registry), Deno and JSR, Node's headers for native modules
	"registry.npmjs.org",
	"registry.yarnpkg.com",
	"jsr.io",
	"*.jsr.io",
	"deno.land",
	"*.deno.land",
	"nodejs.org",
	// Python
	"pypi.org",
	"files.pythonhosted.org",
	// Rust
	"crates.io",
	"index.crates.io",
	"static.crates.io",
	// Go
	"proxy.golang.org",
	"sum.golang.org",
	// Ruby
	"rubygems.org",
	"index.rubygems.org",
	// Java and Kotlin
	"repo.maven.apache.org",
	"repo1.maven.org",
	"plugins.gradle.org",
	"services.gradle.org",
	"downloads.gradle.org",
	// GitHub: clones, releases, raw files, the API
	"github.com",
	"api.github.com",
	"codeload.github.com",
	"*.githubusercontent.com",
];

const PORTS = new Set([80, 443]);

/** Whether `host` matches `pattern`: the same name, or a name under "*.domain" (not the domain itself). */
export function hostMatches(host: string, pattern: string): boolean {
	const p = pattern.trim().toLowerCase().replace(/\.$/, "");
	if (p.startsWith("*.")) return host.endsWith(p.slice(1)) && host.length > p.length - 1;
	return host === p;
}

export type NetworkDecision = "once" | "always" | "deny";

export type NetworkFilterOptions = {
	/** The project's "host" rules, read on every connection. */
	rules: () => readonly string[];
	/** Asks the user about a host; undefined when nobody can answer (the run stopped): refused. */
	ask: (host: string) => Promise<NetworkDecision | undefined>;
	/** Always: the project keeps the host as a rule. */
	addRule: (pattern: string) => void;
	builtIn?: readonly string[];
	/** Tests: where a host really is. */
	route?: (host: string, port: number) => { host: string; port: number };
};

export class NetworkFilter {
	private server?: Server;
	private listening?: Promise<number>;
	private readonly allowed = new Set<string>();
	private readonly denied = new Set<string>();
	private readonly asking = new Map<string, Promise<boolean>>();
	private readonly refused: { host: string; at: number }[] = [];
	private readonly sockets = new Set<Socket>();

	constructor(private readonly opts: NetworkFilterOptions) {}

	/** Starts listening (once) on 127.0.0.1 and gives the port. */
	start(): Promise<number> {
		this.listening ??= new Promise<number>((resolve, reject) => {
			const server = createServer((req, res) => void this.forward(req, res));
			server.on("connect", (req: IncomingMessage, socket: Socket, head: Buffer) => void this.tunnel(req, socket, head));
			server.on("connection", (socket: Socket) => {
				this.sockets.add(socket);
				socket.on("close", () => this.sockets.delete(socket));
			});
			server.once("error", reject);
			server.listen(0, "127.0.0.1", () => resolve((server.address() as { port: number }).port));
			this.server = server;
		});
		return this.listening;
	}

	/** The hosts refused since `at` (ms), each once. */
	refusedSince(at: number): string[] {
		return [...new Set(this.refused.filter((r) => r.at >= at).map((r) => r.host))];
	}

	close(): void {
		for (const s of this.sockets) s.destroy();
		this.server?.close();
	}

	/** Whether `host` may be reached now: the lists, else the user (one question per host at a time). */
	async allows(host: string): Promise<boolean> {
		const h = host.toLowerCase().replace(/\.$/, "");
		if (h === "localhost" || h === "127.0.0.1" || h === "::1") return true;
		if (this.denied.has(h)) return false;
		if (this.allowed.has(h) || [...(this.opts.builtIn ?? BUILT_IN_HOSTS), ...this.opts.rules()].some((p) => hostMatches(h, p))) return true;
		let pending = this.asking.get(h);
		if (!pending) {
			pending = this.opts.ask(h).then(
				(decision) => {
					if (decision === "always") this.opts.addRule(h);
					if (decision === "once" || decision === "always") this.allowed.add(h);
					// A stopped run isn't a no: the next command asks again.
					else if (decision === "deny") this.denied.add(h);
					return decision === "once" || decision === "always";
				},
				() => (this.denied.add(h), false),
			);
			this.asking.set(h, pending);
			void pending.finally(() => this.asking.delete(h));
		}
		return pending;
	}

	private refuse(host: string): void {
		this.refused.push({ host, at: Date.now() });
		if (this.refused.length > 500) this.refused.splice(0, this.refused.length - 500);
	}

	/** HTTPS (and anything else tunneled): CONNECT host:port, then the bytes both ways, unread. */
	private async tunnel(req: IncomingMessage, client: Socket, head: Buffer): Promise<void> {
		client.on("error", () => {});
		const target = parseTarget(req.url ?? "");
		if (!target || !PORTS.has(target.port)) {
			if (target) this.refuse(`${target.host}:${target.port}`);
			return void client.end("HTTP/1.1 403 Forbidden\r\nX-Piopio: network filter\r\n\r\n");
		}
		if (!(await this.allows(target.host))) {
			this.refuse(target.host);
			return void client.end("HTTP/1.1 403 Forbidden\r\nX-Piopio: network filter\r\n\r\n");
		}
		const to = this.opts.route?.(target.host, target.port) ?? target;
		const upstream = tcpConnect(to.port, to.host, () => {
			client.write("HTTP/1.1 200 Connection Established\r\n\r\n");
			if (head.length) upstream.write(head);
			upstream.pipe(client);
			client.pipe(upstream);
		});
		upstream.on("error", () => client.end("HTTP/1.1 502 Bad Gateway\r\n\r\n"));
		client.on("close", () => upstream.destroy());
	}

	/** Plain HTTP through the proxy: an absolute URL ("GET http://host/path"). */
	private async forward(req: IncomingMessage, res: ServerResponse): Promise<void> {
		let url: URL;
		try {
			url = new URL(req.url ?? "");
		} catch {
			return void res.writeHead(400).end("Piopio's network filter takes proxy requests only.");
		}
		const port = Number(url.port || 80);
		if (url.protocol !== "http:" || !PORTS.has(port)) {
			this.refuse(`${url.hostname}:${port}`);
			return void res.writeHead(403, { "x-piopio": "network filter" }).end();
		}
		if (!(await this.allows(url.hostname))) {
			this.refuse(url.hostname);
			return void res.writeHead(403, { "x-piopio": "network filter" }).end(`Piopio's network filter didn't let this project's commands reach ${url.hostname}.`);
		}
		const to = this.opts.route?.(url.hostname, port) ?? { host: url.hostname, port };
		const headers = Object.fromEntries(Object.entries(req.headers).filter(([k]) => !k.startsWith("proxy-")));
		const out = httpRequest({ host: to.host, port: to.port, method: req.method, path: `${url.pathname}${url.search}`, headers }, (up) => {
			res.writeHead(up.statusCode ?? 502, up.headers);
			up.pipe(res);
		});
		out.on("error", () => res.headersSent ? res.destroy() : res.writeHead(502).end());
		req.pipe(out);
	}
}

/** "host:port" (or "[v6]:port") from a CONNECT line. */
function parseTarget(raw: string): { host: string; port: number } | undefined {
	const m = /^\[?([^\]]+?)\]?:(\d+)$/.exec(raw.trim());
	if (!m) return undefined;
	const host = m[1]!.toLowerCase();
	if (!host || (!isIP(host) && !/^[a-z0-9.-]+$/.test(host))) return undefined;
	return { host, port: Number(m[2]) };
}
