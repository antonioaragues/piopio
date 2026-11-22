/**
 * Piopio's additions to the system prompt as pi's own named sections (docs/spec/38 §8 R1). pi diffs the sections before
 * each run and sends only the ones that changed, in place, so a model that accepts system messages mid-conversation
 * keeps its cached prefix. Returning `systemPrompt` from `before_agent_start` instead forces the whole prompt: every
 * provider then gets it as a new leading system message, and any change costs the whole conversation again.
 */
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";

/** The part of pi's `systemPromptOptions` these helpers touch. */
export type PromptOptions = {
	customPrompt?: string;
	selectedTools: string[];
	hiddenTools: string[];
	toolSnippets: Record<string, string>;
	toolGuidelines: Record<string, string[]>;
	promptGuidelines: string[];
	sections: Record<string, string>;
};
export type PromptEvent = { systemPromptOptions: PromptOptions };

/** Sets one named section (pi wraps it in `<name>` tags), or removes it when there's no text. */
export function promptSection(event: PromptEvent, name: string, text: string | undefined): void {
	const value = text?.trim();
	if (value) event.systemPromptOptions.sections[name] = value;
	else delete event.systemPromptOptions.sections[name];
}

/**
 * Piopio's preamble in place of pi's (`customPrompt`, pi's way to replace it). pi leaves its tools list and rules out of
 * a custom prompt, so `tools` and `rules` are kept as sections here, filled at the end of the run's handlers by
 * `promptToolsExtension` (they depend on the tools the other handlers turn on); claiming them now keeps them first.
 * `guidelines` take the place of pi's documentation block, which only helps someone extending pi.
 */
export function piopioBase(event: PromptEvent, preamble: string, guidelines: string): void {
	const options = event.systemPromptOptions;
	options.customPrompt = preamble;
	options.sections.tools ??= " ";
	options.sections.rules ??= " ";
	promptSection(event, "piopio", guidelines);
}

/** pi's tools list, as pi renders it without a custom prompt (pi-coding-agent core/system-prompt.js). */
export function toolsList(options: PromptOptions): string {
	const declared = options.selectedTools.filter((name) => !options.hiddenTools.includes(name));
	const visible = declared.filter((name) => Boolean(options.toolSnippets[name]));
	const tools = visible.length > 0 ? visible.map((name) => `- ${name}: ${options.toolSnippets[name]}`).join("\n") : "(none)";
	return `${tools}\n\nAdditional tools may be available.`;
}

/** pi's rules, as pi renders them without a custom prompt (`buildRules`, same file): the tools' own guidelines first. */
export function rulesList(options: PromptOptions): string {
	const declared = options.selectedTools.filter((name) => !options.hiddenTools.includes(name));
	const rules: string[] = [];
	const seen = new Set<string>();
	const add = (rule: string) => {
		const normalized = rule.trim();
		if (!normalized || seen.has(normalized)) return;
		seen.add(normalized);
		rules.push(normalized);
	};
	const has = (name: string) => declared.includes(name);
	if ((has("bash") || has("powershell")) && !has("grep") && !has("find") && !has("ls")) {
		if (has("bash") && has("powershell")) add("Use bash or PowerShell for file operations like listing, searching, and finding files");
		else if (has("powershell")) add("Use PowerShell for file operations like listing, searching, and finding files");
		else add("Use bash for file operations like ls, rg, find");
	}
	for (const name of declared) for (const rule of options.toolGuidelines[name] ?? []) add(rule);
	for (const rule of options.promptGuidelines) add(rule);
	add("Be concise in your responses");
	add("Show file paths clearly when working with files");
	return rules.map((rule) => `- ${rule}`).join("\n");
}

/** Last among a session's extensions: fills the `tools` and `rules` sections `piopioBase` kept, from the final tool set. */
export function promptToolsExtension(): ExtensionFactory {
	return (pi) => {
		pi.on("before_agent_start", (event) => {
			const options = (event as unknown as PromptEvent).systemPromptOptions;
			if (options.customPrompt === undefined || !("tools" in options.sections)) return undefined;
			options.sections.tools = toolsList(options);
			options.sections.rules = rulesList(options);
			return undefined;
		});
	};
}
