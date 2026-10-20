// A minimal stdio MCP server for tests: one tool, `echo`, that returns its text.
import { createInterface } from "node:readline";

const send = (message) => process.stdout.write(`${JSON.stringify({ jsonrpc: "2.0", ...message })}\n`);
createInterface({ input: process.stdin }).on("line", (line) => {
	if (!line.trim()) return;
	const { id, method, params } = JSON.parse(line);
	if (method === "initialize") {
		send({ id, result: { protocolVersion: params.protocolVersion, capabilities: { tools: {} }, serverInfo: { name: "echo", version: "1.0.0" } } });
	} else if (method === "tools/list") {
		send({ id, result: { tools: [{ name: "echo", description: "Returns its text.", inputSchema: { type: "object", properties: { text: { type: "string" } }, required: ["text"] } }] } });
	} else if (method === "tools/call") {
		send({ id, result: { content: [{ type: "text", text: `echo: ${params.arguments.text}` }] } });
	} else if (id !== undefined) {
		send({ id, result: {} });
	}
});
