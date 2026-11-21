/**
 * Piopio's own `/commands` that are only words for the model (docs/spec/32 §3, CM3): prompt templates bundled with
 * the engine, listed beside the user's in Build and in chats. The app shows them in its own group, with a chip and a
 * hint. A template of the same name in the user's pi folder or a package wins.
 */
import type { PromptTemplate } from "@earendil-works/pi-coding-agent";

type Bundled = { name: string; description: string; hint: string; content: string; needs?: "browser" | "automations" };

export const PIOPIO_PROMPTS: readonly Bundled[] = [
	{
		name: "automation",
		description: "Make an automation: work that starts on its own, once or on a schedule",
		hint: "<what, and when or how often>",
		needs: "automations",
		content: `Make an automation for this: $ARGUMENTS

Use the automate tool. If what it should do, when it should start or where the result goes isn't clear from what I wrote, ask me first with ask_user, one question at a time. Then make it and say in one line what you set.`,
	},
	{
		name: "grill-me",
		description: "Pressure-test an idea: one question at a time until the plan is clear",
		hint: "<the idea>",
		content: `Pressure-test this idea before anything is built: $ARGUMENTS

Ask me one question at a time with ask_user, starting with what matters most: the goal, who it's for, what done looks like, constraints, risks, and what I'd leave out. Offer likely answers as options when you can. Don't change any files and don't start the work. When you can state the plan back without guessing, write it as a short plan (goal, decisions, open questions, first steps) and ask whether it's right.`,
	},
	{
		name: "browser",
		description: "Do it in the browser, where you can watch",
		hint: "<the task>",
		needs: "browser",
		content: `Do this in the browser, where I can watch it in the Browser panel: $ARGUMENTS

Use the browser tools even if you could answer another way. When a page asks me to sign in, prove I'm human or pay, stop and tell me to do it in the Browser panel. When you're done, say what you did and what you found.`,
	},
];

/** pi's templates plus Piopio's (those whose tools this session has), unless one of pi's has the name. */
export function withPiopioPrompts(prompts: PromptTemplate[], has: { browser: boolean; automations: boolean }): PromptTemplate[] {
	const taken = new Set(prompts.map((p) => p.name));
	const own = PIOPIO_PROMPTS.filter((p) => !taken.has(p.name) && (!p.needs || has[p.needs])).map(
		(p): PromptTemplate => ({
			name: p.name,
			description: p.description,
			argumentHint: p.hint,
			content: p.content,
			filePath: `piopio:${p.name}.md`,
			sourceInfo: { path: `piopio:${p.name}.md`, source: "piopio", scope: "temporary", origin: "top-level" },
		}),
	);
	return [...prompts, ...own];
}
