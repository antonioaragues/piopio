import { describe, expect, it } from "vitest";
import type { ConnectorHub } from "../src/connectors/hub.js";
import { connectorsSection, unavailable } from "../src/connectors/tools.js";

/** Just what the prompt section reads: three apps, Linear connected unless `linear` is false. */
function hub(opts: { linear?: boolean; notionChats?: boolean } = {}): ConnectorHub {
	const accounts = [...(opts.linear === false ? [] : [{ id: "linear:w1", connector: "linear", label: "Piopio" }]), { id: "notion:n1", connector: "notion", label: "Notes" }];
	return {
		definitions: [
			{ id: "linear", name: "Linear" },
			{ id: "notion", name: "Notion" },
			{ id: "github", name: "GitHub" },
		],
		accounts: (c?: string) => accounts.filter((a) => !c || a.connector === c),
		settings: (id: string) => ({ chats: id === "notion" ? opts.notionChats ?? true : true, dontAsk: [] }),
		calendars: () => [],
		mailboxes: () => [],
		mcpUses: () => [],
	} as unknown as ConnectorHub;
}

describe("apps a conversation can't use (docs/spec/12-connectors C6)", () => {
	it("says why each one is missing", () => {
		const off = (id: string) => id === "linear";
		expect(unavailable(hub({ notionChats: false }), "chat", off).map((m) => [m.id, m.why.split(":")[0]])).toEqual([
			["linear", "turned off for this conversation by the user"],
			["notion", "not allowed in conversations"],
			["github", "not connected"],
		]);
		// Agents don't follow the chats setting or a conversation's switches.
		expect(unavailable(hub({ notionChats: false }), "agent", off).map((m) => m.id)).toEqual(["github"]);
	});

	it("tells the model to tell the user, not to ask another agent", () => {
		const text = connectorsSection(hub({ linear: false }), "chat")!;
		expect(text).toContain("Not available in this conversation: Linear (not connected: the user can connect it in Settings › Connectors)");
		expect(text).toContain("Never ask another agent to do it for you.");
		expect(text).toContain("For an app the user turned off, don't reach it any other way either");
	});
});
