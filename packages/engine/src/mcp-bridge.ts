/**
 * A stdio MCP server that forwards to an HTTP one: `node mcp-bridge.js <url>`. For coding agents that start MCP
 * servers as commands but can't reach HTTP (Antigravity CLI), pointed at Piopio's tool server (tool-server.ts). Each
 * JSON-RPC line from the agent is POSTed as it is; the answer (plain JSON) goes back as a line. No imports from the
 * project: Node runs it as it is, and the app's bundle ships it next to the engine.
 */
const url = process.argv[2];
if (!url) {
	process.stderr.write("usage: mcp-bridge <url>\n");
	process.exit(2);
}

const out = (message: unknown) => process.stdout.write(`${JSON.stringify(message)}\n`);

async function forward(line: string): Promise<void> {
	let message: { id?: unknown };
	try {
		message = JSON.parse(line);
	} catch {
		return;
	}
	try {
		const res = await fetch(url!, { method: "POST", headers: { "content-type": "application/json", accept: "application/json, text/event-stream" }, body: line });
		if (res.status === 202 || res.status === 204) return;
		const text = await res.text();
		if (!res.ok) throw new Error(`Piopio answered ${res.status}`);
		const answer = JSON.parse(text);
		for (const m of Array.isArray(answer) ? answer : [answer]) out(m);
	} catch (error) {
		if (message.id !== undefined) out({ jsonrpc: "2.0", id: message.id, error: { code: -32603, message: `Piopio isn't reachable: ${(error as Error).message}` } });
	}
}

let buf = "";
process.stdin.setEncoding("utf8");
process.stdin.on("data", (d: string) => {
	buf += d;
	let i: number;
	while ((i = buf.indexOf("\n")) >= 0) {
		const line = buf.slice(0, i).trim();
		buf = buf.slice(i + 1);
		if (line) void forward(line);
	}
});
process.stdin.on("end", () => process.exit(0));
