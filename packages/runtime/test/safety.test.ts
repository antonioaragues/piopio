import { describe as group, expect, test } from "vitest";
import { allowKey, matches } from "../src/agents/safety.js";

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
