/**
 * The context guards for Build sessions (pi SDK): the model's clock and the repeated-call nudge, the same as chats and
 * agents get through `contextGuardsExtension` (@piopio/runtime context/). Applied to each request only; the session
 * file keeps the messages as they were. pi already bounds its own tools' output and MCP results, saving the rest to a file.
 * Also Build's working rules (WORKING_RULES), added to the system prompt every turn.
 */
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { guardMessages, localZone } from "@piopio/runtime";

/**
 * Stop when the request is done (docs/research/deepseek-harness.md, "As built"). A real run (2026-11-09, DeepSeek in Full auto):
 * "push to main" took 30 seconds, then 7 more minutes of work nobody asked for: it reworded a commit with an interactive
 * rebase, watched CI with `sleep` and `gh run watch`, fixed what failed, and committed and pushed again.
 */
export const WORKING_RULES = `How to work in Piopio:
- Do what the user asked, then stop and report. Follow-ups the request didn't ask for (watching CI, fixing what a check turns up, more cleanup, another commit) are offers in your answer: name them and let the user say yes.
- Push, publish or deploy only what the user asked for, once; another push needs their go-ahead. Don't rewrite history (rebase, amend, force-push) unless asked: get a commit message right before you commit.
- Don't make the user wait on a timer: no sleep loops or commands that watch for minutes (gh run watch, tail -f). Check once, and say how to follow it or offer to check again.`;

export function guardsExtension(tz: () => string = localZone): ExtensionFactory {
	return (pi) => {
		pi.on("before_agent_start", (event) => ({ systemPrompt: `${event.systemPrompt}\n\n${WORKING_RULES}` }));
		pi.on("context", (event) => {
			const messages = guardMessages(event.messages as never[], tz());
			return messages === (event.messages as unknown) ? undefined : { messages };
		});
	};
}
