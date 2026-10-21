// A minimal stdio MCP memory server for tests: remember, search, list and forget per bank, kept in a JSON file
// (argv[2]) so separate connections see the same memories. `--no-list` leaves out list (limited visibility).
import { existsSync, readFileSync, writeFileSync } from "node:fs";
import { createInterface } from "node:readline";

const file = process.argv[2];
const withList = !process.argv.includes("--no-list");
const load = () => (existsSync(file) ? JSON.parse(readFileSync(file, "utf8")) : []);
const save = (all) => writeFileSync(file, JSON.stringify(all));
const tools = [
	{ name: "remember", description: "Store a memory", inputSchema: { type: "object", properties: { text: { type: "string" }, user: { type: "string" } }, required: ["text", "user"] } },
	{ name: "search", description: "Search memories", inputSchema: { type: "object", properties: { query: { type: "string" }, user: { type: "string" } }, required: ["query", "user"] } },
	...(withList ? [{ name: "all_memories", description: "List memories", inputSchema: { type: "object", properties: { user: { type: "string" } }, required: ["user"] } }] : []),
	{ name: "forget", description: "Delete a memory", inputSchema: { type: "object", properties: { id: { type: "string" } }, required: ["id"] } },
];
const text = (t) => ({ content: [{ type: "text", text: typeof t === "string" ? t : JSON.stringify(t) }] });
const send = (message) => process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
createInterface({ input: process.stdin }).on("line", (line) => {
	if (!line.trim()) return;
	const { id, method, params } = JSON.parse(line);
	if (method === "initialize") return send({ id, result: { protocolVersion: params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "memory", version: "1.0.0" } } });
	if (method === "tools/list") return send({ id, result: { tools } });
	if (method === "tools/call") {
		const a = params.arguments ?? {};
		const all = load();
		if (params.name === "remember") {
			all.push({ id: `mem${all.length + 1}`, user: a.user, memory: a.text, created_at: "2026-10-21T10:00:00Z" });
			save(all);
			return send({ id, result: text({ status: "ok" }) });
		}
		if (params.name === "search") {
			const words = String(a.query).toLowerCase().split(/\W+/).filter((w) => w.length > 2);
			const hits = all.filter((m) => m.user === a.user && words.some((w) => m.memory.toLowerCase().includes(w)));
			return send({ id, result: text({ results: hits }) });
		}
		if (params.name === "all_memories") return send({ id, result: text({ memories: all.filter((m) => m.user === a.user) }) });
		if (params.name === "forget") {
			save(all.filter((m) => m.id !== a.id));
			return send({ id, result: text("forgotten") });
		}
	}
	if (id !== undefined) send({ id, result: {} });
});
