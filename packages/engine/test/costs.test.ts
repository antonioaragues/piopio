import { expect, test } from "vitest";
import { ExtraCosts } from "../src/costs.js";

test("known extra costs and missing billing information remain distinct", () => {
	const costs = new ExtraCosts();
	try {
		costs.record("web_search", "model", 0.02, "thread-a");
		costs.record("web_search", "model", undefined, "thread-a");
		costs.record("utility", "model", 0.003);
		expect(costs.summary("thread-a")).toMatchObject({ calls: 2, knownUsd: 0.02, unknownCalls: 1 });
		expect(costs.summary()).toMatchObject({ calls: 3, knownUsd: 0.023, unknownCalls: 1 });
		expect(costs.summary("other")).toMatchObject({ calls: 0, knownUsd: 0, unknownCalls: 0 });
	} finally { costs.close(); }
});

test("an agent's extra costs for a month, for its budget", () => {
	const costs = new ExtraCosts();
	try {
		const month = new Date().toISOString().slice(0, 7);
		costs.record("web_search", "model", 0.02, "agent-a");
		costs.record("utility", "model", 0.005, "agent-a");
		costs.record("utility", "model", undefined, "agent-a");
		costs.record("web_search", "model", 0.5, "agent-b");
		expect(costs.monthUsd("agent-a", month)).toBeCloseTo(0.025);
		expect(costs.monthUsd("agent-a", "1999-01")).toBe(0);
		expect(costs.monthUsd("nobody", month)).toBe(0);
	} finally { costs.close(); }
});
