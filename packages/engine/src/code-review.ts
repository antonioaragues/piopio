/**
 * Review by an agent (docs/spec/05-build "Review by an agent", roadmap PAR4): what a reviewer session is told, and the
 * `report_findings` tool it reports with. The review runs as a Build session of its own in Read only; its findings
 * land on the session it reviewed (sessions.ts `review`), where the user fixes or dismisses them.
 */
import { defineTool, type ExtensionFactory } from "@earendil-works/pi-coding-agent";
import type { ReviewFinding } from "@piopio/protocol";
import { Type } from "typebox";

/** What the reviewer reports; ids and state are Piopio's. */
export type ReportedFinding = Omit<ReviewFinding, "id" | "state">;
export type ReviewBridge = { report(summary: string, findings: ReportedFinding[]): string };

/** The diff kept in the review's first message (an attachment's limit is 200,000 characters). */
export const MAX_DIFF = 190_000;

/** The reviewer's first message: what to review and how to report. */
export function reviewPrompt(target: string, notes = ""): string {
	return [
		`Review ${target}. The diff is attached as changes.diff${notes ? `; ${notes}` : ""}.`,
		"",
		"Correctness first. Look for, in this order:",
		"1. Bugs: code that breaks something or does the wrong thing. Say when it happens: which input, which path.",
		"2. Risks: security holes, lost or corrupted data, races, missing error handling, changed behaviour other code relies on.",
		"3. At most three nits, only when they matter (a misleading name, dead code).",
		"Read the files around a change before judging it: a diff alone misses callers and context. Don't report style the",
		"project's formatter decides, or things you can't point at in the code. Fewer, sure findings beat many guesses.",
		"",
		"When you're done, call report_findings once: each finding with its file (as in the diff), the line in the new code,",
		"its severity (bug, risk or nit), a one-line title, what goes wrong and when, and a fix. With nothing worth",
		"reporting, call it with no findings and say so in the summary.",
	].join("\n");
}

export function codeReviewExtension(bridge: ReviewBridge): ExtensionFactory {
	return (pi) => {
		pi.registerTool(
			defineTool({
				name: "report_findings",
				label: "Report findings",
				description: "Reports your review to the user: a summary and the findings, each tied to a file and line. Call it once, when you're done.",
				promptSnippet: "report_findings: hand your review to the user",
				parameters: Type.Object({
					summary: Type.String({ description: "Two or three sentences: what you reviewed and how it looks" }),
					findings: Type.Array(
						Type.Object({
							severity: Type.Union([Type.Literal("bug"), Type.Literal("risk"), Type.Literal("nit")]),
							file: Type.String({ description: "The file's path, as in the diff" }),
							line: Type.Optional(Type.Number({ description: "The line in the new version" })),
							title: Type.String({ description: "One line" }),
							detail: Type.String({ description: "What goes wrong, and when" }),
							suggestion: Type.Optional(Type.String({ description: "How to fix it" })),
						}),
					),
				}),
				async execute(_id, params) {
					const text = bridge.report(params.summary, params.findings as ReportedFinding[]);
					return { content: [{ type: "text", text }], details: {} };
				},
			}),
		);
	};
}
