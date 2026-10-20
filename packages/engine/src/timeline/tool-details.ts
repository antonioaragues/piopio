/**
 * What tool cards show beyond the raw output (docs/spec/05-build BR1), from pi's built-in tools:
 * edit → its unified patch, write → the new file as added lines, bash → command + exit code, read → path.
 */
import type { ToolDetails } from "@piopio/protocol";

type Args = Record<string, unknown>;
/** pi's tool result: `details` is tool-specific and persisted in the session file; `structuredContent` is live only. */
export type PiToolResult = { details?: unknown; structuredContent?: unknown };

const MAX_WRITE_LINES = 2000;

/** Details known when the call starts (path, command), so a running card already says what it does. */
export function startDetails(tool: string, args: unknown): ToolDetails | undefined {
	const a = (args ?? {}) as Args;
	const path = typeof a.path === "string" ? a.path : undefined;
	switch (tool) {
		case "bash":
			return typeof a.command === "string" ? { type: "terminal", command: a.command } : undefined;
		case "read":
			return path ? { type: "file", path, ...language(path) } : undefined;
		case "edit":
			return path ? { type: "diff", path, diff: "" } : undefined;
		case "write":
			return path && typeof a.content === "string" ? { type: "diff", path, diff: newFilePatch(a.content) } : undefined;
		case "todo":
			return Array.isArray(a.items) ? { type: "todos", items: a.items as { text: string; status: "pending" | "in_progress" | "done" }[] } : undefined;
		case "task":
			return { type: "task" };
		default:
			return undefined;
	}
}

/** Details once the call finished. */
export function endDetails(tool: string, args: unknown, result: PiToolResult | undefined, output: string | undefined, isError: boolean): ToolDetails | undefined {
	const start = startDetails(tool, args);
	if (!start) return undefined;
	if (tool === "task") {
		const d = (result?.details ?? {}) as { sessionId?: string; status?: "done" | "error" | "stopped"; costUsd?: number };
		return { type: "task", ...(d.sessionId ? { sessionId: d.sessionId } : {}), ...(d.status ? { status: d.status } : {}), ...(typeof d.costUsd === "number" ? { costUsd: d.costUsd } : {}) };
	}
	if (tool === "edit" && start.type === "diff") {
		const patch = (result?.details as { patch?: unknown } | undefined)?.patch;
		return typeof patch === "string" ? { ...start, diff: patch } : isError ? undefined : start;
	}
	if (tool === "bash" && start.type === "terminal") {
		const exitCode = (result?.structuredContent as { exit_code?: unknown } | undefined)?.exit_code;
		if (typeof exitCode === "number") return { ...start, exitCode };
		const reported = /Command exited with code (\d+)\s*$/.exec(output ?? "")?.[1];
		if (reported) return { ...start, exitCode: Number(reported) };
		return isError ? start : { ...start, exitCode: 0 };
	}
	return start;
}

/** A whole new file as a unified patch of added lines (capped). */
export function newFilePatch(content: string): string {
	const lines = content.replace(/\n$/, "").split("\n");
	const shown = lines.slice(0, MAX_WRITE_LINES);
	const body = shown.map((l) => `+${l}`).join("\n");
	const more = lines.length > shown.length ? `\n… ${lines.length - shown.length} more lines` : "";
	return `@@ -0,0 +1,${lines.length} @@\n${body}${more}`;
}

function language(path: string): { language?: string } {
	const ext = /\.([A-Za-z0-9]+)$/.exec(path)?.[1]?.toLowerCase();
	return ext ? { language: ext } : {};
}
