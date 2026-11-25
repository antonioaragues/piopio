import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { CAPTURE_LINE, aboutMeExtension, aboutMeSdkExtension, type AboutMe } from "../src/about-me.js";
import { Settings } from "../src/settings.js";

// Re-audit 2026-11-25 V8: About me is in every conversation's prompt, so nothing the model reads may write it. A chat
// proposes facts on the /learn card; a chat on a coding agent (no card) and an agent only read it.

async function setup() {
	const home = mkdtempSync(join(tmpdir(), "piopio-aboutme-"));
	const settings = new Settings(join(home, "settings.json"));
	settings.set({ aboutMe: { enabled: true, capture: true, inThreads: true, inAgents: true } });
	const store = { promptText: async () => "## Home\n- Lives in Valencia" } as unknown as AboutMe;
	return { settings, store };
}

/** The tools a chat extension registers, and its about-me section for one turn. */
async function chat(factory: ReturnType<typeof aboutMeSdkExtension>) {
	const tools: string[] = [];
	let start: ((event: unknown) => Promise<unknown>) | undefined;
	factory({ on: (name: string, fn: never) => name === "before_agent_start" && (start = fn), registerTool: (t: { name: string }) => tools.push(t.name) } as never);
	const event = { systemPromptOptions: { sections: {} as Record<string, string> } };
	await start!(event);
	return { tools, section: event.systemPromptOptions.sections["about-me"] ?? "" };
}

test("a chat has no tool that writes About me, and is told to propose on the /learn card", async () => {
	const { settings, store } = await setup();
	const c = await chat(aboutMeSdkExtension(store, settings));
	expect(c.tools).toEqual([]);
	expect(c.section).toContain(CAPTURE_LINE);
	expect(CAPTURE_LINE).toContain("propose_learnings");
	settings.set({ aboutMe: { capture: false } });
	expect((await chat(aboutMeSdkExtension(store, settings))).section).not.toContain("propose_learnings");
});

test("a chat on a coding agent and an agent read About me and are asked to save nothing", async () => {
	const { settings, store } = await setup();
	const coding = await chat(aboutMeSdkExtension(store, settings, { proposes: false }));
	expect(coding.tools).toEqual([]);
	expect(coding.section).toContain("About me");
	expect(coding.section).not.toContain("propose_learnings");
	const agent = aboutMeExtension(store, settings, "agent") as unknown as { tools: unknown[] };
	expect(agent.tools).toEqual([]);
});
