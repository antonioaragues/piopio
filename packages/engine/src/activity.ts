/**
 * Overview › Activity (docs/spec/34 §7): what Piopio did in a range, each number beside the same range before. It
 * counts what's already stored (the catalog, automation runs, the usage ledger and its activity index); it tracks
 * nothing new and shows nothing it can't count: no "time saved", no scores or streaks (OV5).
 */
import type { ActivityResult, SessionSummary, SpendRange } from "@piopio/protocol";
import type { AutomationRun } from "./automations/model.js";
import { rangeBounds, type UsageLedger } from "./ledger.js";

type Row = ActivityResult["groups"][number]["rows"][number];

export type ActivityContext = {
	ledger: UsageLedger;
	sessions: readonly SessionSummary[];
	runs: readonly AutomationRun[];
	automationName: (id: string) => string | undefined;
	agentName: (id: string) => string | undefined;
	now?: Date;
};

/** The range before, of the same kind: yesterday, the 7 days before, last month, the 12 months before. */
export function previousBounds(range: SpendRange, now = new Date()): { from: Date; to: Date } {
	const { from, to } = rangeBounds(range, now);
	if (range === "today" || range === "7d") return { from: new Date(from.getTime() - (to.getTime() - from.getTime())), to: from };
	if (range === "12m") return { from: new Date(from.getFullYear() - 1, from.getMonth(), 1), to: from };
	return { from: new Date(from.getFullYear(), from.getMonth() - 1, 1), to: from };
}

export function activity(range: SpendRange, ctx: ActivityContext): ActivityResult {
	const now = ctx.now ?? new Date();
	const cur = rangeBounds(range, now);
	const prev = previousBounds(range, now);
	const first = ctx.ledger.firstAt() ?? [...ctx.sessions].map((s) => s.createdAt).sort()[0];
	// No "previous" before Piopio existed.
	const hasPrev = first !== undefined && new Date(first) < prev.to;
	const a = counts(cur, ctx);
	const b = hasPrev ? counts(prev, ctx) : undefined;
	const row = (id: keyof Counts, label: string, extra: Partial<Row> = {}): Row => ({ id, label, value: a[id] as number, ...(b ? { previous: b[id] as number } : {}), ...extra });
	const groups: ActivityResult["groups"] = [
		{ id: "conversations", title: "Conversations", rows: [row("started", "Conversations started"), row("messages", "Messages you sent"), row("side", "Side conversations"), row("subagents", "Subagents")] },
		{ id: "build", title: "Build", rows: [row("buildSessions", "Sessions"), row("files", "Files changed", { unit: "files" }), row("prsOpened", "Pull requests opened"), row("prsMerged", "Pull requests merged"), row("worktreesMerged", "Worktrees merged")] },
		{
			id: "agents",
			title: "Agents",
			rows: [row("agentRuns", "Runs", a.topAgent ? { detail: `most by ${a.topAgent}` } : {}), row("agentMessages", "Messages to agents"), row("undone", "Results undone")],
		},
		{
			id: "automations",
			title: "Automations",
			rows: [
				row("autoRuns", "Runs"),
				row("autoDone", "Finished"),
				row("autoSkipped", "Skipped"),
				row("autoFailed", "Failed", a.mostFailed ? { detail: `${a.mostFailed} failed most` } : {}),
				row("autoWaited", "Waited for you"),
			],
		},
		{
			id: "you",
			title: "You and Piopio",
			rows: [
				row("toolCalls", "Tool calls", a.topTools ? { detail: a.topTools } : {}),
				row("denied", "Tool calls you denied"),
				row("agentApprovals", "Agents asked you", a.agentApprovals ? { detail: `${a.agentApprovalsAllowed} allowed` } : {}),
			],
		},
		{ id: "reliability", title: "Reliability", rows: [row("errors", "Provider errors", a.topError ? { detail: a.topError } : {}), row("toolErrors", "Tools that failed"), row("compactions", "Compactions")] },
	];
	return { range, from: cur.from.toISOString(), to: cur.to.toISOString(), groups, year: yearOfDays(ctx.ledger, first, now) };
}

type Counts = {
	started: number; messages: number; side: number; subagents: number;
	buildSessions: number; files: number; prsOpened: number; prsMerged: number; worktreesMerged: number;
	agentRuns: number; agentMessages: number; undone: number; topAgent?: string;
	autoRuns: number; autoDone: number; autoSkipped: number; autoFailed: number; autoWaited: number; mostFailed?: string;
	denied: number; agentApprovals: number; agentApprovalsAllowed: number; toolCalls: number; topTools?: string;
	errors: number; toolErrors: number; compactions: number; topError?: string;
};

function counts({ from, to }: { from: Date; to: Date }, ctx: ActivityContext): Counts {
	const inRange = (at?: string) => at !== undefined && at >= from.toISOString() && at < to.toISOString();
	const made = ctx.sessions.filter((s) => inRange(s.createdAt));
	const own = made.filter((s) => !s.parent && !s.side && !s.helper && s.ref.kind !== "agent");
	const acts = ctx.ledger.activityRows(from, to);
	const of = (kind: string) => acts.filter((r) => r.kind === kind);
	const tools = of("tool");
	const approvals = of("approval");
	const errors = of("error");
	const runs = ctx.runs.filter((r) => inRange(r.firedAt));
	const ledger = ctx.ledger.rows(from, to);
	// An agent's run is a conversation of its own ("<agent>/run:<id>"); counted once however many requests it made.
	const agentRuns = new Map<string, Set<string>>();
	for (const r of ledger) if (r.agent && r.source.includes("/run:")) agentRuns.set(r.agent, (agentRuns.get(r.agent) ?? new Set()).add(r.source));
	const topAgent = [...agentRuns].sort((x, y) => y[1].size - x[1].size)[0];
	const failed = new Map<string, number>();
	for (const r of runs) if (r.status === "failed") failed.set(r.automation, (failed.get(r.automation) ?? 0) + 1);
	const mostFailed = [...failed].sort((x, y) => y[1] - x[1])[0];
	const byTool = new Map<string, number>();
	for (const t of tools) if (t.name) byTool.set(t.name, (byTool.get(t.name) ?? 0) + 1);
	const byError = new Map<string, number>();
	for (const e of errors) byError.set(e.name ?? "other", (byError.get(e.name ?? "other") ?? 0) + 1);
	const topError = [...byError].sort((x, y) => y[1] - x[1])[0];
	const updatedIn = (s: SessionSummary) => inRange(s.updatedAt);
	const agentIds = new Set(ctx.sessions.filter((s) => s.ref.kind === "agent").map((s) => s.ref.id));
	return {
		started: own.filter((s) => s.ref.kind === "thread").length,
		messages: of("message").filter((m) => !m.source.includes("/run:")).length,
		side: made.filter((s) => s.side).length,
		subagents: made.filter((s) => s.parent).length,
		buildSessions: own.filter((s) => s.ref.kind === "build").length,
		files: new Set(of("file").map((f) => `${f.source}\u0000${f.name}`)).size,
		prsOpened: ctx.sessions.filter((s) => s.pr && inRange(s.createdAt)).length,
		prsMerged: ctx.sessions.filter((s) => s.pr?.state === "merged" && updatedIn(s)).length,
		worktreesMerged: ctx.sessions.filter((s) => s.worktree?.finished === "merged" && updatedIn(s)).length,
		agentRuns: [...agentRuns.values()].reduce((n, set) => n + set.size, 0),
		agentMessages: of("message").filter((m) => !m.source.includes("/run:") && agentIds.has(m.source.split("/")[0]!)).length,
		undone: of("undone").length,
		...(topAgent ? { topAgent: ctx.agentName(topAgent[0]) ?? "an agent" } : {}),
		autoRuns: runs.length,
		autoDone: runs.filter((r) => r.status === "done" || r.status === "quiet").length,
		autoSkipped: runs.filter((r) => r.status === "skipped").length,
		autoFailed: runs.filter((r) => r.status === "failed").length,
		autoWaited: runs.filter((r) => r.status === "waiting" || r.held).length,
		...(mostFailed && mostFailed[1] > 1 ? { mostFailed: ctx.automationName(mostFailed[0]) ?? "An automation" } : {}),
		// Build's approvals leave nothing when allowed, so only denials are counted there; agents' approvals are items.
		denied: tools.filter((t) => t.status === "denied").length,
		agentApprovals: approvals.length,
		agentApprovalsAllowed: approvals.filter((r) => r.status === "approved").length,
		toolCalls: tools.length,
		...(byTool.size ? { topTools: [...byTool].sort((x, y) => y[1] - x[1]).slice(0, 3).map(([name]) => name).join(", ") } : {}),
		errors: errors.length,
		toolErrors: tools.filter((t) => t.status === "error").length,
		compactions: of("compaction").length,
		...(topError ? { topError: `mostly ${topError[0].replace(/_/g, " ")}` } : {}),
	};
}

/** From the day Piopio started (or a year ago), each local day's count. */
function yearOfDays(ledger: UsageLedger, first: string | undefined, now: Date): ActivityResult["year"] {
	const yearAgo = new Date(now.getFullYear() - 1, now.getMonth(), now.getDate() + 1);
	const start = first ? new Date(Math.max(new Date(first).getTime(), yearAgo.getTime())) : new Date(now.getFullYear(), now.getMonth(), now.getDate());
	const from = new Date(start.getFullYear(), start.getMonth(), start.getDate());
	const to = new Date(now.getFullYear(), now.getMonth(), now.getDate() + 1);
	const per = ledger.perDay(from, to);
	const out: ActivityResult["year"] = [];
	for (let d = new Date(from); d < to; d = new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1)) {
		const day = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
		out.push({ day, count: per.get(day) ?? 0 });
	}
	return out;
}
