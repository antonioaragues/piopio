/**
 * The context guards for Build sessions (pi SDK): the model's clock and the repeated-call nudge, the same as chats and
 * agents get through `contextGuardsExtension` (@piopio/runtime context/). Applied to each request only; the session
 * file keeps the messages as they were. pi already bounds its own tools' output and MCP results, saving the rest to a file.
 */
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import type { ToolExecutionResult } from "@earendil-works/pi-durable";
import { FailureGuard, guardMessages, localZone } from "@piopio/runtime";

export function guardsExtension(tz: () => string = localZone): ExtensionFactory {
	return (pi) => {
		// The stop for a tool that keeps failing the same way, as agents have (runtime/context/failures.ts): the third
		// same failure in a turn gets a note to stop and tell the user; after that the tool is blocked until the next
		// message, and blocked calls that keep coming end the run.
		const failures = new FailureGuard();
		const here = "session";
		pi.on("tool_call", (event) => {
			const call = { id: event.toolCallId, name: event.toolName };
			const reason = failures.before(here, call);
			if (!reason) return undefined;
			const ended = failures.after(here, call, { output: [{ type: "text", text: reason }], isError: true } as ToolExecutionResult);
			return { block: true, reason, ...(ended?.control?.terminate ? { terminate: true } : {}) };
		});
		pi.on("tool_result", (event) => {
			const noted = failures.after(here, { id: event.toolCallId, name: event.toolName }, { output: event.content, isError: event.isError } as ToolExecutionResult);
			return noted?.output ? { content: noted.output as typeof event.content } : undefined;
		});
		// `context_with_system`, not `context`: a `context` handler that changes the conversation makes pi fold every
		// system message into one leading prompt, so a prompt change in place (docs/spec/38 §8 R1) was undone on each
		// request. The guards only touch user messages and tool results, and keep each message where it is.
		pi.on("context_with_system", (event) => {
			failures.request(here, event.messages as never[]);
			const messages = guardMessages(event.messages as never[], tz());
			return messages === (event.messages as unknown) ? undefined : { messages };
		});
	};
}
