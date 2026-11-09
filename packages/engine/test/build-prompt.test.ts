import { expect, test } from "vitest";
import { buildPromptExtension, modelLabel, PI_PREAMBLE, PIOPIO_GUIDELINES, piopioSystemPrompt } from "../src/tools/build-prompt.js";

/** pi's own renderer, which the package doesn't export: found next to its entry point. */
async function piPrompt(): Promise<string> {
	const entry = import.meta.resolve("@earendil-works/pi-coding-agent");
	const { buildSystemPrompt } = (await import(new URL("./core/system-prompt.js", entry).href)) as { buildSystemPrompt: (o: object) => string };
	return buildSystemPrompt({ cwd: "/p", selectedTools: ["read", "bash", "edit", "write"], toolSnippets: { read: "Read files" }, contextFiles: [{ path: "/p/AGENTS.md", content: "Use tabs." }] });
}

test("Build's prompt: Piopio's preamble and guidelines replace pi's, and pi's tools, rules and AGENTS.md stay (docs/research/system-prompts.md)", async () => {
	const pi = await piPrompt();
	// If pi changes its wording, this fails here instead of silently leaving pi's preamble and docs in every turn.
	expect(pi.startsWith(PI_PREAMBLE)).toBe(true);
	expect(pi).toContain("\n\n<docs>\n");
	const prompt = piopioSystemPrompt(pi, "DeepSeek V4.1 Flash");
	expect(prompt.startsWith("You are the agent in Piopio, a Mac app, powered by the DeepSeek V4.1 Flash model.")).toBe(true);
	expect(prompt).not.toContain("operating inside pi");
	expect(prompt).not.toContain("<docs>");
	expect(prompt).toContain("<tools>\n- read: Read files");
	expect(prompt).toContain("<rules>");
	expect(prompt).toContain("Use tabs.");
	// The guidelines sit where pi's docs were: after its rules, before the project's instructions.
	expect(prompt.indexOf("<rules>")).toBeLessThan(prompt.indexOf("<piopio>"));
	expect(prompt.indexOf("<piopio>")).toBeLessThan(prompt.indexOf("Use tabs."));
	// A prompt that isn't pi's still gets the guidelines, at the end.
	expect(piopioSystemPrompt("Custom")).toBe(`Custom\n\n${PIOPIO_GUIDELINES}`);
});

test("the guidelines carry the rules from real runs: stop when done, one push, no timers, others' changes, unrelated bugs", () => {
	for (const rule of ["then stop and report", "another push needs their go-ahead", "gh run watch", "Never revert or overwrite them", "mention it in your answer instead of fixing it", "Look before you ask", "`path:line`", "[Piopio: …]"]) {
		expect(PIOPIO_GUIDELINES).toContain(rule);
	}
	// Short enough to stay a few clear rules.
	expect(PIOPIO_GUIDELINES.length).toBeLessThan(3_200);
});

test("the extension names the session's model as the app does", () => {
	expect(modelLabel("DeepSeek: DeepSeek V4.1 Flash")).toBe("DeepSeek V4.1 Flash");
	expect(modelLabel("Claude Haiku 5.5")).toBe("Claude Haiku 5.5");
	expect(modelLabel(undefined)).toBeUndefined();
	let handler: ((event: { systemPrompt: string }, ctx: { model?: { name?: string; id: string } }) => { systemPrompt: string }) | undefined;
	buildPromptExtension()({ on: (name: string, fn: typeof handler) => void (name === "before_agent_start" && (handler = fn)) } as never);
	const out = handler!({ systemPrompt: `${PI_PREAMBLE}\n\n<cwd>\n/p\n</cwd>` }, { model: { name: "Anthropic: Claude Haiku 5.5", id: "anthropic/claude-haiku-5.5" } }).systemPrompt;
	expect(out.startsWith("You are the agent in Piopio, a Mac app, powered by the Claude Haiku 5.5 model.")).toBe(true);
});

test("a model whose name already ends in 'model' isn't 'the … model model'", () => {
	expect(piopioSystemPrompt(PI_PREAMBLE, "Faux Model").startsWith("You are the agent in Piopio, a Mac app, powered by Faux Model.")).toBe(true);
});
