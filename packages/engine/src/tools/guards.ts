/**
 * The context guards for Build sessions (pi SDK): the model's clock and the repeated-call nudge, the same as chats and
 * agents get through `contextGuardsExtension` (@piopio/runtime context/). Applied to each request only; the session
 * file keeps the messages as they were. pi already bounds its own tools' output and MCP results, saving the rest to a file.
 */
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { guardMessages, localZone } from "@piopio/runtime";

export function guardsExtension(tz: () => string = localZone): ExtensionFactory {
	return (pi) => {
		// `context_with_system`, not `context`: a `context` handler that changes the conversation makes pi fold every
		// system message into one leading prompt, so a prompt change in place (docs/spec/38 §8 R1) was undone on each
		// request. The guards only touch user messages and tool results, and keep each message where it is.
		pi.on("context_with_system", (event) => {
			const messages = guardMessages(event.messages as never[], tz());
			return messages === (event.messages as unknown) ? undefined : { messages };
		});
	};
}
