import { describe, expect, test } from "vitest";
import { cronError, newDefinition, partitionsFor, TEMPLATES, validate } from "../src/index.js";

describe("agent definitions", () => {
	test("every template makes a valid definition", () => {
		for (const t of TEMPLATES) {
			const { definition, instructions } = newDefinition({ id: "agt_1", slug: "coach", name: "Coach", owner: "Antonio", model: "anthropic/claude-haiku-5.5", template: t.id });
			expect(validate(definition)).toEqual([]);
			expect(instructions).toContain("Antonio");
		}
	});

	test("schema and semantic errors carry paths", () => {
		const { definition } = newDefinition({ id: "agt_1", slug: "coach", name: "Coach", owner: "Antonio", model: "m" });
		expect(validate({ ...definition, slug: "Not A Slug" })[0]!.path).toBe("/slug");
		const bad = {
			...definition,
			contacts: [...definition.contacts, { id: "owner", name: "Again", role: "owner" as const, channels: { whatsapp: "600111222" } }],
			schedules: [{ id: "x", cron: "61 8 * * *", prompt: "hi", deliverTo: "nobody" }],
			tools: { builtin: ["memory" as const], agents: ["agt_1", "agt_ghost"] },
		};
		expect(validate(bad, { knownAgents: ["agt_1"], knownModels: () => false })).toEqual([
			{ path: "/contacts/1/id", message: "Two contacts have the id “owner”." },
			{ path: "/contacts", message: "Only one contact can be the owner." },
			{ path: "/contacts/1/channels/whatsapp", message: "A WhatsApp number in international format, like +34600111222." },
			{ path: "/schedules/0/cron", message: "The minute must be between 0 and 59." },
			{ path: "/schedules/0/deliverTo", message: "No contact “nobody”." },
			{ path: "/tools/agents/0", message: "An agent can't contact itself." },
			{ path: "/tools/agents/1", message: "No agent “agt_ghost”." },
			{ path: "/models/default", message: "Unknown model “m”." },
		]);
		expect(cronError("0 8 * * 1-5")).toBeUndefined();
		expect(cronError("*/15 9-17 * * mon")).toBe("The day of week field “mon” isn't valid.");
		expect(cronError("0 8 * *")).toContain("five fields");
	});

	test("partitions keep contacts apart", () => {
		expect(partitionsFor({ id: "owner", role: "owner" })).toEqual({ read: ["owner", "shared"], write: ["owner", "shared"], home: "owner" });
		expect(partitionsFor({ id: "maria", role: "contact" })).toEqual({ read: ["shared", "contacts/maria"], write: ["contacts/maria"], home: "contacts/maria" });
	});
});
