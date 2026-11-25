import { expect, test } from "vitest";
import type { ConnectorHub } from "../src/connectors/hub.js";
import { codingConnectorsExtension, durableConnectorsExtension } from "../src/connectors/extension.js";
import { collectTools } from "../src/runtimes/claude-code-tools.js";

/** A hub with no app connected until `connect()` adds a calendar. */
function hub() {
	const calendars: unknown[] = [];
	const h = {
		definitions: [],
		accounts: () => [],
		settings: () => ({ chats: true, dontAsk: [] }),
		calendars: () => calendars,
		mailboxes: () => [],
		mcpUses: () => [],
	} as unknown as ConnectorHub;
	return { hub: h, connect: () => calendars.push({ name: "Google Calendar", account: { id: "google:1", connector: "google", label: "me@example.com" }, calendar: {} }) };
}
const confirm = () => async () => ({ approved: true });
const appTools = (names: readonly string[]) => names.filter((n) => n.startsWith("calendar_") || n.startsWith("mail_")).sort();

test("Build: the calendar and mail tools are on only while an account of theirs is connected, read each turn", async () => {
	const { hub: h, connect } = hub();
	const registered: string[] = [];
	let active: string[] = [];
	const handlers: Record<string, ((event: object) => unknown)[]> = {};
	codingConnectorsExtension(h, confirm)({
		registerTool: (t: { name: string }) => (registered.push(t.name), active.push(t.name)),
		getAllTools: () => registered.map((name) => ({ name })),
		getActiveTools: () => [...active],
		setActiveTools: (names: string[]) => (active = [...names]),
		on: (name: string, fn: (event: object) => unknown) => (handlers[name] ??= []).push(fn),
	} as never);
	const turn = () => handlers.before_agent_start!.forEach((fn) => fn({ systemPromptOptions: { sections: {} } }));
	handlers.session_start!.forEach((fn) => fn({}));
	expect(appTools(registered).length).toBe(9);
	expect(appTools(active)).toEqual([]);
	connect();
	turn();
	expect(appTools(active).every((n) => n.startsWith("calendar_"))).toBe(true);
	expect(appTools(active).length).toBeGreaterThan(0);
});

test("agents and coding agents get the calendar and mail tools only with an account connected", () => {
	const { hub: h, connect } = hub();
	const names = (ext: unknown) => (ext as { tools: { name: string }[] }).tools.map((t) => t.name);
	expect(appTools(names(durableConnectorsExtension(h, "agent", confirm)))).toEqual([]);
	expect(appTools(collectTools([codingConnectorsExtension(h, confirm)]).tools.map((t) => t.name))).toEqual([]);
	connect();
	expect(appTools(names(durableConnectorsExtension(h, "agent", confirm))).length).toBeGreaterThan(0);
	const coding = appTools(collectTools([codingConnectorsExtension(h, confirm)]).tools.map((t) => t.name));
	expect(coding.length).toBeGreaterThan(0);
	expect(coding.every((n) => n.startsWith("calendar_"))).toBe(true);
});

test("a coding agent gets an app's deferred tools too: it has no tool_search, so they're served directly", () => {
	// Re-audit 2026-11-25 §5.2 said collectTools dropped the deferred ones; this keeps them served.
	const { hub: h } = hub();
	const def = { id: "linear", name: "Linear", description: "Issues", mcp: { prefix: "linear" } };
	const tools = Array.from({ length: 14 }, (_, i) => ({ name: `tool_${i}`, description: `Tool ${i}`, inputSchema: { type: "object" }, access: "read" }));
	Object.assign(h, { mcpUses: () => [{ def, tools, account: { id: "linear:1", label: "acme" }, call: async () => ({ text: "" }) }], permission: () => "allow" });
	const served = collectTools([codingConnectorsExtension(h, confirm)]).tools.map((t) => t.name).filter((n) => n.startsWith("linear_"));
	expect(served.length).toBe(14);
});
