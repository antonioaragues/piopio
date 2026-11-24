/**
 * `propose_learnings` (docs/spec/14 M5, /learn): the model proposes what this conversation taught, as a card the user
 * saves, edits or dismisses. The tool writes nothing and waits for nothing: the card answers itself, later or never.
 */
import { Type } from "typebox";
import { defineTool, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import type { LearnItem, ToolDetails } from "@piopio/protocol";

export interface LearnBridge {
	/** The project folder a rule goes into, or undefined (a chat): then only facts about the user can be proposed. */
	project(): string | undefined;
	/** The instructions file in that project ("AGENTS.md" or "CLAUDE.md"). */
	file(): string | undefined;
	/** About me can take facts (off in a temporary chat, and when About me is off). */
	aboutMe(): boolean;
	/** The card is up: it waits for the user from here. */
	proposed(callId: string): void;
	/** Your skills' names, so a skill can be added to one of them (docs/spec/40 SH0). */
	skills(): Promise<string[]>;
}

const params = Type.Object({
	items: Type.Array(
		Type.Object({
			to: Type.Union([Type.Literal("project"), Type.Literal("about_me"), Type.Literal("skill")], { description: "project: a rule for this project's instructions file; about_me: something lasting about the user; skill: how to do a kind of job the user walked you through, to repeat later in any project" }),
			text: Type.String({ description: "The rule or fact, one short sentence, as it should be written. For a skill: when it's used (\"When asked to cut a release of this app\")" }),
			why: Type.String({ description: "What in this conversation shows it, in a few words (\"you corrected the test command\")" }),
			section: Type.Optional(Type.String({ description: "project only: the instructions file's section it belongs under, e.g. Testing, Conventions, Releases" })),
			name: Type.Optional(Type.String({ description: "skill only: a short name, lowercase-with-hyphens (release-piopio)" })),
			body: Type.Optional(Type.String({ description: "skill only: its instructions in Markdown: numbered steps with the real commands and paths, and what to check" })),
			add_to: Type.Optional(Type.String({ description: "skill only: the name of one of the user's skills to add this to, instead of a new one" })),
			project_only: Type.Optional(Type.Boolean({ description: "skill only: only for this project (its .pi/skills)" })),
		}),
		{ minItems: 1, maxItems: 8 },
	),
});

const DESCRIPTION = `Propose what this conversation taught, for the user to keep: rules for this project's instructions file (commands, conventions, pitfalls the user corrected or explained) and lasting facts about the user. They show as a card the user saves, edits or dismisses; nothing is written until then, so don't write them to files yourself. Propose only what will still be true next time and isn't already in the instructions. Propose a skill only when the user walked you through a whole job worth repeating (a release, a monthly report), with its real steps. Never a secret, a credential or personal detail in a project rule or a skill.`;

export function learnSdkExtension(bridge: LearnBridge): ExtensionFactory {
	return (pi) => {
		pi.registerTool(
			defineTool({
				name: "propose_learnings",
				label: "Learn",
				description: DESCRIPTION,
				promptSnippet: "propose_learnings: offer what this conversation taught (project rules, facts about the user) as a card the user saves",
				parameters: params as never,
				async execute(callId, raw) {
					const asked = (raw as { items: (LearnItem & { add_to?: string; project_only?: boolean })[] }).items ?? [];
					const project = bridge.project();
					const mine = asked.some((i) => i.to === "skill") ? await bridge.skills() : [];
					const items: LearnItem[] = asked
						.map((i) => ({ ...i, text: i.text?.trim() ?? "" }))
						.filter((i) => i.text && (i.to === "project" ? Boolean(project) : i.to === "about_me" ? bridge.aboutMe() : i.to === "skill" && Boolean(i.name?.trim() && i.body?.trim())))
						.map(({ to, text, why, section, name, body, add_to, project_only }) => ({
							to,
							text,
							...(why ? { why } : {}),
							...(to === "project" && section?.trim() ? { section: section.trim() } : {}),
							...(to === "skill" ? { name: name!.trim(), body: body!.trim(), ...(add_to && mine.includes(add_to) ? { addTo: add_to } : {}), ...(project_only && project ? { projectOnly: true } : {}) } : {}),
						}));
					if (!items.length) {
						const why = !project && asked.some((i) => i.to === "project") ? "This conversation has no project, so there's no instructions file to add rules to." : "Nothing to propose here.";
						return { content: [{ type: "text", text: why }], details: {}, isError: true } as never;
					}
					bridge.proposed(callId);
					const file = items.some((i) => i.to === "project") ? bridge.file() : undefined;
					const details: ToolDetails = { type: "learn", ...(file ? { file } : {}), items };
					const text = `Proposed ${items.length} thing${items.length === 1 ? "" : "s"} to keep, on a card. The user saves, edits or dismisses them there; don't write them anywhere yourself. Say in one line what you proposed, then carry on.`;
					return { content: [{ type: "text", text }], details };
				},
			}),
		);
	};
}

/** /learn (a Piopio prompt template): with words, keep exactly that; without, look back at the conversation. */
export const LEARN_PROMPT = `Keep what this conversation taught. $ARGUMENTS

If I wrote something after /learn, that is what to keep: propose exactly that, worded as a rule for this project or as a fact about me, whichever it is. Otherwise look back at this conversation for what's worth keeping: what I corrected, what I explained about how this project works, what turned out to be the way to do things here, and lasting facts about me, and any whole job I walked you through that's worth repeating as a skill. Leave out what's only true today or already in the project's instructions.

Then call propose_learnings once, with at most five items, each with why. Don't write any file yourself.`;
