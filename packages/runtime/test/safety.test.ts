import { describe as group, expect, test } from "vitest";
import { allowKey, matches, Safety } from "../src/agents/safety.js";

group("approval rules (06 §9 AS1)", () => {
	test("tool names, recipients, methods and MCP tools", () => {
		expect(matches("send_message", "send_message", { to: "owner" }, "owner")).toBe(true);
		expect(matches("send_message:to_non_owner", "send_message", { to: "owner" }, "owner")).toBe(false);
		expect(matches("send_message:to_non_owner", "send_message", { to: "maria" }, "owner")).toBe(true);
		expect(matches("send_message:to_owner", "send_message", { to: "owner" }, "owner")).toBe(true);
		expect(matches("send_message:to:maria", "send_message", { to: "luis" }, "owner")).toBe(false);
		expect(matches("http_request:POST", "http_request", { method: "post" }, "owner")).toBe(true);
		expect(matches("http_request:POST", "http_request", {}, "owner")).toBe(false);
		expect(matches("*", "remember", {}, "owner")).toBe(true);
		expect(matches("sched*", "schedule", {}, "owner")).toBe(true);
		expect(matches("sched*", "send_message", {}, "owner")).toBe(false);
		expect(matches("mcp:*:write", "notion_write", {}, "owner")).toBe(true);
		expect(matches("mcp:notion:*", "github_write", {}, "owner")).toBe(false);
		expect(matches("remember:something_new", "remember", {}, "owner")).toBe(true);
	});

	test("what Always allow remembers", () => {
		expect(allowKey("send_message", { to: "maria", text: "hi" })).toBe("send_message:to:maria");
		expect(allowKey("http_request", { method: "post" })).toBe("http_request:POST");
		expect(allowKey("schedule", { when: "x" })).toBe("schedule");
	});
});

group("budget (06 §9 AS3)", () => {
	const safetyWith = (harnessUsd: number, extraUsd: number | undefined, budget: number) => {
		let state: Record<string, unknown> = {};
		const host = {
			harness: { usage: async () => ({ models: { m: { cost: { total: harnessUsd } } }, tools: {} }) },
			context: {},
			definition: () => ({ name: "Ada", contacts: [], policies: { budgetUsdPerMonth: budget } }),
			now: () => Date.parse("2026-11-06T12:00:00Z"),
			read: async () => state,
			write: async (change: (s: Record<string, unknown>) => void) => { const next = structuredClone(state); change(next); state = next; },
			...(extraUsd === undefined ? {} : { extraSpend: (month: string) => (month === "2026-11" ? extraUsd : 0) }),
		};
		return new Safety(host as never);
	};

	test("web search and utility requests outside the harness count toward the monthly budget", async () => {
		expect(await safetyWith(0.4, 0.2, 1).spend()).toBeCloseTo(0.6);
		expect(await safetyWith(0.7, 0.4, 1).gate()).toMatchObject({ ok: false, reason: "budget" });
		expect(await safetyWith(0.7, undefined, 1).gate()).toEqual({ ok: true });
	});
});

// Re-audit 2026-11-25 V4: a contact's message could make the agent read pages in a browser signed in for the owner.
group("what a contact can't make the agent do (06 §9 AS2)", () => {
	const safetyFor = (who: { contact?: { id: string; name: string; role: string }; peerId?: string }) => {
		let state: Record<string, unknown> = {};
		const host = {
			harness: { usage: async () => ({ models: {}, tools: {} }) },
			context: {},
			definition: () => ({ name: "Ada", contacts: [], policies: {} }),
			now: () => Date.parse("2026-11-25T12:00:00Z"),
			read: async () => state,
			write: async (change: (s: Record<string, unknown>) => void) => { const next = structuredClone(state); change(next); state = next; },
			whose: async () => who,
		};
		return new Safety(host as never);
	};
	const before = (safety: Safety, name: string) => safety.beforeTool({ id: "c1", name, arguments: { url: "https://bank.example/" } }, { conversationId: "conv", taskId: "t" } as never, {} as never);

	test("use the browser: it's signed in for the owner", async () => {
		const maria = safetyFor({ contact: { id: "maria", name: "María", role: "contact" } });
		for (const tool of ["browser_open", "browser_read", "browser_screenshot", "browser_click"]) {
			expect(await before(maria, tool), tool).toEqual({ block: expect.stringContaining("can't make you use the browser") });
		}
	});
	test("the owner, the agent's own runs and other agents of the owner still browse", async () => {
		for (const who of [{ contact: { id: "owner", name: "Antonio", role: "owner" } }, {}, { contact: { id: "maria", name: "María", role: "contact" }, peerId: "scout" }]) {
			expect(await before(safetyFor(who), "browser_read"), JSON.stringify(who)).toBeUndefined();
		}
	});
});
