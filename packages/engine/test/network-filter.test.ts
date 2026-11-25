import { createServer as createHttp } from "node:http";
import { connect, createServer, type Server } from "node:net";
import { afterEach, expect, test } from "vitest";
import { BUILT_IN_HOSTS, hostMatches, NetworkFilter, type NetworkDecision } from "../src/network-filter.js";

// The network filter (docs/spec/39) against local stand-ins: every "host" is routed to a server on this Mac.
const closing: { close(): void }[] = [];
afterEach(() => {
	for (const c of closing.splice(0)) c.close();
});

async function echo(): Promise<number> {
	const server: Server = createServer((s) => s.pipe(s));
	closing.push(server);
	await new Promise<void>((r) => server.listen(0, "127.0.0.1", () => r()));
	return (server.address() as { port: number }).port;
}

/** CONNECT through the proxy, then a line back from the echo server: the status line, and the echo when it opened. */
function tunnel(proxy: number, target: string, say = "hello"): Promise<{ status: string; echoed?: string }> {
	return new Promise((resolve, reject) => {
		const s = connect(proxy, "127.0.0.1", () => s.write(`CONNECT ${target} HTTP/1.1\r\nHost: ${target}\r\n\r\n`));
		let buf = "";
		let status: string | undefined;
		s.on("data", (d) => {
			buf += d.toString();
			if (!status && buf.includes("\r\n\r\n")) {
				status = buf.split("\r\n")[0]!;
				buf = buf.slice(buf.indexOf("\r\n\r\n") + 4);
				if (!status.includes(" 200 ")) return resolve({ status });
				s.write(say);
			}
			if (status && buf.includes(say)) {
				s.destroy();
				resolve({ status, echoed: buf });
			}
		});
		s.on("error", reject);
		s.on("end", () => status && resolve({ status }));
	});
}

function filter(answer: (host: string) => Promise<NetworkDecision | undefined>, rules: string[] = [], up = 0) {
	const asked: string[] = [];
	const added: string[] = [];
	const f = new NetworkFilter({
		rules: () => rules,
		ask: (host) => (asked.push(host), answer(host)),
		addRule: (p) => added.push(p),
		builtIn: ["registry.example", "*.cdn.example"],
		route: (_host, _port) => ({ host: "127.0.0.1", port: up }),
	});
	closing.push(f);
	return { f, asked, added };
}

test("a name matches itself, and *.domain matches names under it but not the domain", () => {
	expect(hostMatches("github.com", "github.com")).toBe(true);
	expect(hostMatches("raw.githubusercontent.com", "*.githubusercontent.com")).toBe(true);
	expect(hostMatches("githubusercontent.com", "*.githubusercontent.com")).toBe(false);
	expect(hostMatches("evilgithub.com", "github.com")).toBe(false);
	expect(hostMatches("x.evil-githubusercontent.com", "*.githubusercontent.com")).toBe(false);
	expect(BUILT_IN_HOSTS).toContain("registry.npmjs.org");
});

test("a listed host or a project's rule tunnels without asking; ports other than 80 and 443 never do", async () => {
	const up = await echo();
	const { f, asked } = filter(async () => "deny", ["api.mine.example"], up);
	const port = await f.start();
	expect(await tunnel(port, "registry.example:443")).toMatchObject({ status: "HTTP/1.1 200 Connection Established", echoed: "hello" });
	expect((await tunnel(port, "a.cdn.example:443")).echoed).toBe("hello");
	expect((await tunnel(port, "api.mine.example:443")).echoed).toBe("hello");
	expect((await tunnel(port, "registry.example:22")).status).toBe("HTTP/1.1 403 Forbidden");
	expect(asked).toEqual([]);
	expect(f.refusedSince(0)).toEqual(["registry.example:22"]);
});

test("another host waits for the user, asked once however many connections want it; no is refused for the session", async () => {
	const up = await echo();
	let say!: (d: NetworkDecision) => void;
	const { f, asked } = filter(() => new Promise((r) => (say = r)), [], up);
	const port = await f.start();
	const at = Date.now();
	const both = Promise.all([tunnel(port, "evil.example:443"), tunnel(port, "evil.example:443")]);
	await new Promise((r) => setTimeout(r, 100));
	expect(asked).toEqual(["evil.example"]);
	say("deny");
	expect((await both).map((r) => r.status)).toEqual(["HTTP/1.1 403 Forbidden", "HTTP/1.1 403 Forbidden"]);
	expect((await tunnel(port, "evil.example:443")).status).toBe("HTTP/1.1 403 Forbidden");
	expect(asked).toEqual(["evil.example"]);
	expect(f.refusedSince(at)).toEqual(["evil.example"]);
});

test("allowed once lasts the session; always also becomes the project's rule", async () => {
	const up = await echo();
	const { f, asked, added } = filter(async (host) => (host === "once.example" ? "once" : "always"), [], up);
	const port = await f.start();
	expect((await tunnel(port, "once.example:443")).echoed).toBe("hello");
	expect((await tunnel(port, "once.example:443")).echoed).toBe("hello");
	expect((await tunnel(port, "keep.example:443")).echoed).toBe("hello");
	expect(asked).toEqual(["once.example", "keep.example"]);
	expect(added).toEqual(["keep.example"]);
});

test("plain HTTP is forwarded to an allowed host, and refused with a note for another", async () => {
	const web = createHttp((req, res) => res.end(`got ${req.url}`));
	closing.push(web);
	await new Promise<void>((r) => web.listen(0, "127.0.0.1", () => r()));
	const up = (web.address() as { port: number }).port;
	const { f } = filter(async () => "deny", [], up);
	const port = await f.start();
	const get = (url: string) =>
		new Promise<{ status: number; body: string }>((resolve) => {
			const s = connect(port, "127.0.0.1", () => s.write(`GET ${url} HTTP/1.1\r\nHost: x\r\nConnection: close\r\n\r\n`));
			let buf = "";
			s.on("data", (d) => (buf += d));
			s.on("end", () => resolve({ status: Number(buf.split(" ")[1]), body: buf.slice(buf.indexOf("\r\n\r\n") + 4) }));
		});
	expect(await get("http://registry.example/left-pad")).toEqual({ status: 200, body: "got /left-pad" });
	const no = await get("http://elsewhere.example/x");
	expect(no.status).toBe(403);
	expect(no.body).toContain("didn't let this project's commands reach elsewhere.example");
});

// Re-audit 2026-11-25 V5: an allowed name was connected to wherever it resolved at that moment, LAN and 169.254.169.254
// included (DNS rebinding). Now a name is resolved once in the filter and refused when it points at a private address.
test("an allowed name that resolves to this Mac or a private network is refused, tunneled or forwarded", async () => {
	const addresses: Record<string, string[]> = { "registry.example": ["10.0.0.5"], "api.mine.example": ["93.184.216.34", "169.254.169.254"], "a.cdn.example": ["::ffff:127.0.0.1"], "gone.cdn.example": [] };
	const f = new NetworkFilter({ rules: () => ["api.mine.example"], ask: async () => "deny", addRule: () => {}, builtIn: ["registry.example", "*.cdn.example"], resolve: async (h) => addresses[h] ?? [] });
	closing.push(f);
	const port = await f.start();
	for (const host of ["registry.example", "api.mine.example", "a.cdn.example", "gone.cdn.example"]) {
		const r = await tunnel(port, `${host}:443`);
		expect(r.status, host).toBe("HTTP/1.1 403 Forbidden");
	}
	const body = await new Promise<string>((resolve) => {
		const s = connect(port, "127.0.0.1", () => s.write("GET http://registry.example/x HTTP/1.1\r\nHost: registry.example\r\nConnection: close\r\n\r\n"));
		let buf = "";
		s.on("data", (d) => (buf += d.toString()));
		s.on("end", () => resolve(buf));
	});
	expect(body).toContain("403");
	expect(body).toContain("resolves to a local or private address");
	expect(f.refusedSince(0)).toEqual(["registry.example", "api.mine.example", "a.cdn.example", "gone.cdn.example"]);
});
