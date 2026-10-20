/**
 * piopio-checkpoints: before the first tool that can change files in each agent run (edit, write, bash),
 * asks the host to snapshot the working tree (docs/spec/05-build §7, CK1). Piopio keeps the snapshots in
 * a shadow git repository; without a bridge (pi CLI) it does nothing.
 */
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";

export interface CheckpointBridge {
	/** Snapshots the working tree before `callId` runs. Failures are ignored: checkpoints never block work. */
	snapshot(callId: string): Promise<void>;
}

const MAY_CHANGE_FILES = new Set(["edit", "write", "bash"]);

export function checkpointsExtension(bridge?: CheckpointBridge): ExtensionFactory {
	let taken = false;
	return (pi) => {
		if (!bridge) return;
		pi.on("agent_start", () => {
			taken = false;
		});
		pi.on("tool_call", async (event) => {
			if (taken || !MAY_CHANGE_FILES.has(event.toolName)) return undefined;
			taken = true;
			await bridge.snapshot(event.toolCallId).catch(() => undefined);
			return undefined;
		});
	};
}
