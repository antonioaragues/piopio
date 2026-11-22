import { expect, test } from "vitest";
import { buildPromptExtension, modelLabel, PI_PREAMBLE, PIOPIO_GUIDELINES } from "../src/tools/build-prompt.js";
import { chatPromptExtension } from "../src/tools/chat-prompt.js";
import { promptToolsExtension, type PromptOptions } from "../src/tools/prompt-sections.js";

type PiPrompt = {
	buildSystemPrompt: (o: object) => string;
	buildSystemPromptSections: (o: object) => Record<string, string>;
	normalizeBuildSystemPromptOptions: (o: object) => PromptOptions & { cwd: string };
};

/** pi's own renderer, which the package doesn't export: found next to its entry point. */
async function pi(): Promise<PiPrompt> {
	const entry = import.meta.resolve("@earendil-works/pi-coding-agent");
	return (await import(new URL("./core/system-prompt.js", entry).href)) as PiPrompt;
}

const INPUT = { cwd: "/p", selectedTools: ["read", "bash", "edit", "write"], toolSnippets: { read: "Read files" }, toolGuidelines: { edit: ["Read a file before editing it"] }, contextFiles: [{ path: "/p/AGENTS.md", content: "Use tabs." }] };
type Handler = (event: object, ctx: object) => unknown;

/** Runs extensions' before_agent_start handlers in order on pi's options, as pi does, then renders with pi. */
async function render(factories: ((p: never) => void)[], model = "Anthropic: Claude Haiku 5.5"): Promise<{ prompt: string; options: PromptOptions; returned: unknown[] }> {
	const p = await pi();
	const options = p.normalizeBuildSystemPromptOptions(INPUT);
	const handlers: Handler[] = [];
	for (const f of factories) f({ on: (name: string, fn: Handler) => void (name === "before_agent_start" && handlers.push(fn)) } as never);
	const returned: unknown[] = [];
	for (const h of handlers) returned.push(await h({ systemPrompt: p.buildSystemPrompt(options), systemPromptOptions: options }, { model: { name: model, id: "x" } }));
	return { prompt: p.buildSystemPrompt(options), options, returned };
}

test("Build's prompt: Piopio's preamble and guidelines replace pi's, and pi's tools, rules and AGENTS.md stay (docs/research/system-prompts.md)", async () => {
	const p = await pi();
	const plain = p.buildSystemPrompt(INPUT);
	// If pi changes its wording, this fails here instead of silently leaving pi's preamble and docs in every turn.
	expect(plain.startsWith(PI_PREAMBLE)).toBe(true);
	expect(plain).toContain("\n\n<docs>\n");
	const { prompt, returned } = await render([buildPromptExtension(), promptToolsExtension()], "DeepSeek: DeepSeek V4.1 Flash");
	// Nothing is forced: pi's own sections carry it all, so pi sends only what changes (docs/spec/38 §8 R1).
	expect(returned.every((r) => r === undefined)).toBe(true);
	expect(prompt.startsWith("You are the agent in Piopio, a Mac app, powered by the DeepSeek V4.1 Flash model.")).toBe(true);
	expect(prompt).not.toContain("running inside pi");
	expect(prompt).not.toContain("<docs>");
	expect(prompt).toContain("<tools>\n- read: Read files");
	expect(prompt).toContain("<rules>\n");
	expect(prompt).toContain(`<piopio>\n${PIOPIO_GUIDELINES}\n</piopio>`);
	expect(prompt).toContain("Use tabs.");
	expect(prompt.indexOf("<tools>")).toBeLessThan(prompt.indexOf("<rules>"));
	expect(prompt.indexOf("<rules>")).toBeLessThan(prompt.indexOf("<piopio>"));
});

test("the tools list and rules Piopio keeps are pi's own, byte for byte", async () => {
	const p = await pi();
	const own = p.buildSystemPromptSections(INPUT);
	const { options } = await render([buildPromptExtension(), promptToolsExtension()]);
	expect(`<tools>\n${options.sections.tools}\n</tools>`).toBe(own.tools);
	expect(`<rules>\n${options.sections.rules}\n</rules>`).toBe(own.rules);
});

test("a chat's prompt: its preamble, its guidelines and the web, as sections", async () => {
	const { prompt, returned } = await render([chatPromptExtension(() => true), promptToolsExtension()]);
	expect(returned.every((r) => r === undefined)).toBe(true);
	expect(prompt.startsWith("You are the assistant in Piopio, a Mac app, powered by the Claude Haiku 5.5 model.")).toBe(true);
	expect(prompt).toContain("<web>\n");
	expect((await render([chatPromptExtension(() => false), promptToolsExtension()])).prompt).not.toContain("<web>");
});

test("the guidelines carry the rules from real runs: stop when done, one push, no timers, others' changes, unrelated bugs", () => {
	for (const rule of ["then stop and report", "another push needs their go-ahead", "gh run watch", "Never revert or overwrite them", "mention it in your answer instead of fixing it", "Look before you ask", "`path:line`", "[Piopio: …]", "hand over its HTML file with present_files", "file:// address"]) {
		expect(PIOPIO_GUIDELINES).toContain(rule);
	}
	// Short enough to stay a few clear rules.
	expect(PIOPIO_GUIDELINES.length).toBeLessThan(3_200);
});

test("the extension names the session's model as the app does", async () => {
	expect(modelLabel("DeepSeek: DeepSeek V4.1 Flash")).toBe("DeepSeek V4.1 Flash");
	expect(modelLabel("Claude Haiku 5.5")).toBe("Claude Haiku 5.5");
	expect(modelLabel(undefined)).toBeUndefined();
	expect((await render([buildPromptExtension(), promptToolsExtension()])).prompt.startsWith("You are the agent in Piopio, a Mac app, powered by the Claude Haiku 5.5 model.")).toBe(true);
});

test("a model whose name already ends in 'model' isn't 'the … model model'", async () => {
	expect((await render([buildPromptExtension(), promptToolsExtension()], "Faux Model")).prompt.startsWith("You are the agent in Piopio, a Mac app, powered by Faux Model.")).toBe(true);
});
