/**
 * piopio-approvals: asks before tool calls the session's approval mode doesn't allow (docs/spec/05-build §6).
 * In Piopio the engine passes a bridge (prompt cards, per-project rules). In the pi CLI it falls back to
 * pi's own select dialog, with rules kept for the session.
 */
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { decide, type ApprovalMode, type Rule } from "./policy.js";

export type ApprovalRequest = {
	callId: string;
	tool: string;
	input: Record<string, unknown>;
	title: string;
	detail: string;
	reason?: string;
	rule?: Rule;
};
export type ApprovalAnswer = { decision: "allow" | "always" | "deny"; note?: string };

export interface ApprovalBridge {
	mode(): ApprovalMode;
	rules(): readonly Rule[];
	/** Waits for the user. Resolves "deny" when the run is stopped. */
	ask(request: ApprovalRequest, signal: AbortSignal | undefined): Promise<ApprovalAnswer>;
	addRule(rule: Rule): void;
}

/** Blocked calls carry this, so the transcript can tell "denied" from "failed" (also after a reload). */
export const DENIED_PREFIX = "The user denied this tool call";

export function approvalsExtension(bridge?: ApprovalBridge): ExtensionFactory {
	const sessionRules: Rule[] = [];
	return (pi) => {
		pi.on("tool_call", async (event, ctx) => {
			const input = event.input as Record<string, unknown>;
			const mode = bridge?.mode() ?? cliMode();
			const decision = decide(mode, event.toolName, input, ctx.cwd, bridge?.rules() ?? sessionRules);
			if (decision.action === "allow") return undefined;
			const request: ApprovalRequest = {
				callId: event.toolCallId,
				tool: event.toolName,
				input,
				...describe(event.toolName, input),
				...(decision.reason ? { reason: decision.reason } : {}),
				...(decision.rule ? { rule: decision.rule } : {}),
			};
			let answer: ApprovalAnswer;
			if (bridge) {
				answer = await bridge.ask(request, ctx.signal);
			} else if (ctx.hasUI) {
				const options = ["Allow once", ...(request.rule ? [`Always allow ${request.rule.pattern}`] : []), "Deny"];
				const choice = await ctx.ui.select(`${request.title}${request.reason ? ` (${request.reason})` : ""}: ${request.detail}`, options);
				answer = { decision: choice === "Allow once" ? "allow" : choice?.startsWith("Always") ? "always" : "deny" };
			} else {
				answer = { decision: "deny", note: "nobody is there to approve it" };
			}
			if (answer.decision === "always" && request.rule) {
				if (bridge) bridge.addRule(request.rule);
				else sessionRules.push(request.rule);
			}
			if (answer.decision === "deny") {
				return { block: true, reason: `${DENIED_PREFIX}${answer.note ? `: ${answer.note}` : "."}` };
			}
			return undefined;
		});
	};
}

/** Card title and monospace detail for a call. */
export function describe(tool: string, input: Record<string, unknown>): { title: string; detail: string } {
	const path = typeof input.path === "string" ? input.path : "";
	switch (tool) {
		case "bash":
			return { title: "Run a command", detail: String(input.command ?? "") };
		case "edit":
			return { title: "Edit a file", detail: path };
		case "write":
			return { title: "Write a file", detail: path };
		case "read":
		case "grep":
		case "find":
		case "ls":
			return { title: "Read", detail: path || String(input.pattern ?? "") };
		case "web_fetch":
			return { title: "Open a web page", detail: String(input.url ?? "") };
		case "web_search":
			return { title: "Search the web", detail: String(input.query ?? "") };
		default:
			return { title: `Use ${tool}`, detail: JSON.stringify(input).slice(0, 200) };
	}
}

function cliMode(): ApprovalMode {
	const mode = process.env.PIOPIO_APPROVAL_MODE;
	return mode === "ask" || mode === "full_auto" ? mode : "auto_edit";
}
