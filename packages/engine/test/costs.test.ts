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
