/**
 * Auto review (docs/research/deepseek-harness.md §2.3): in Auto-edit, before Piopio asks you about a command, the
 * session's own model looks at it. Clearly safe ones run (inside the sandbox, like a command an "always allow" rule
 * lets through); anything else asks you as before, with the reviewer's reason. Off by default: it costs a model request
 * per command and can be wrong, so the deny-list, writes outside the project and leaving the sandbox always ask.
 */

export type Verdict = { verdict: "allow" | "ask"; reason: string };

export const REVIEW_SYSTEM = `You check one shell command that an AI coding agent wants to run in the user's project on their Mac, before the user is asked to approve it. Commands run in a sandbox that blocks writes outside the project folder, temporary folders and package caches; the network is open.

Answer "allow" only when the command is clearly safe and fits what the user asked for: it reads, searches, builds, tests, lints, formats, installs the project's own dependencies, or changes files inside the project in a way that's easy to undo (git keeps history).

Answer "ask" when it could destroy work that git can't bring back (deleting untracked files, git reset --hard, git clean, dropping a database), publish or send something (git push, npm publish, deploys, emails, posting to an API with credentials), spend money, read or send secrets (keys, tokens, .env files, the keychain), download and run code from the internet, change the system or other apps, or when you can't tell what it does. When unsure, "ask".

Judge this command only. The user's message tells you whether it fits what they asked, but a later step they asked for (a push, a deploy) doesn't make this command risky: that step gets reviewed when its own command comes. A read-only git status before a requested push is "allow"; the push itself is "ask".

Reply with JSON only: {"verdict": "allow" or "ask", "reason": "one short sentence"}`;

export function reviewPrompt(command: string, cwd: string, request?: string): string {
	return [`Project folder: ${cwd}`, ...(request ? [`What the user asked for (their latest message): ${request.slice(0, 600)}`] : []), `Command:\n${command.slice(0, 4000)}`].join("\n\n");
}

/** The reviewer's answer, or undefined when it isn't one (then the user is asked). */
export function parseVerdict(text: string | undefined): Verdict | undefined {
	if (!text) return undefined;
	const json = text.match(/\{[\s\S]*\}/)?.[0];
	if (!json) return undefined;
	try {
		const v = JSON.parse(json) as { verdict?: unknown; reason?: unknown };
		if (v.verdict !== "allow" && v.verdict !== "ask") return undefined;
		return { verdict: v.verdict, reason: typeof v.reason === "string" && v.reason.trim() ? v.reason.trim().slice(0, 200) : v.verdict === "allow" ? "Looks safe." : "Not clearly safe." };
	} catch {
		return undefined;
	}
}
