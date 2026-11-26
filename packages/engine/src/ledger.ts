/**
 * The usage ledger (docs/spec/34 §8.1): one row per paid request, written as it happens, so Overview can group what
 * Piopio spent by day, agent, automation, model, provider, project and place. Refs and numbers only: no prompts, no
 * content, no credentials.
 *
 * Rows come from what sessions show (an assistant answer carries its `Usage`) and from the requests outside them
 * (utility, web search, embeddings: `recordCost`), which it is the only store of (`extra-costs.db` was folded in,
 * 2026-11-26): a conversation's Cost and an agent's budget read them here. Writing is idempotent: a row's id is its
 * container, the answer's item id and its token counts, so reading a conversation again (backfill, a reopen, the live
 * events) never counts an answer twice, and a branch you left keeps what it cost. Answers read from a stored file's
 * other branches (`fromFile`) have no item id to match: one is added only when its conversation has no row with the
 * same model and token counts, so it can't double what's shown (two such requests would count once: an undercount).
 */
import { DatabaseSync, type StatementSync } from "node:sqlite";
import { basename } from "node:path";
import type { AssistantItem, Budget, ContainerRef, SpendGroup, SpendGroupBy, SpendItem, SpendRange, SpendResult, TimelineItem } from "@piopio/protocol";
import { SQLITE_PRAGMAS } from "./requests.js";

export type LedgerKind = "turn" | "utility" | "web_search" | "embedding";
/** A request outside a conversation's turns, as the code that pays for it names it. */
export type CostKind = "web_search" | "utility" | "embeddings";
/** What Cost shows for one conversation or agent, or for all of them (`usage.extras`). */
export type CostSummary = { scope: string; knownUsd: number; unknownCalls: number; calls: number; breakdown: { kind: string; calls: number; knownUsd: number; unknownCalls: number }[] };

/** Where a conversation's requests belong: what opens it, and what it's part of. */
export type LedgerSource = {
	/** The conversation: a session id, or "<agent>/<conversationId>" (search's key). */
	key: string;
	/** Its container: a session id, or the agent's id (one agent is one pi-durable session: entry ids are unique in it). */
	container: string;
	ref: ContainerRef;
	title: string;
	/** "thread" | "build" | "agent"; helpers and subagents count as Build when they work in a project. */
	sourceKind: string;
	project?: string;
	agent?: string;
	automation?: string;
	/** "mac" | "cloud:<id>". */
	place: string;
};

export type LedgerRow = {
	id: string;
	at: string;
	place: string;
	kind: LedgerKind;
	source: string;
	sourceKind: string;
	project?: string;
	agent?: string;
	automation?: string;
	provider?: string;
	route?: string;
	model?: string;
	role?: string;
	input: number;
	output: number;
	cacheRead: number;
	cacheWrite: number;
	usd: number | null;
	plan: boolean;
};

type Stored = {
	id: string; at: string; place: string; kind: string; source: string; source_kind: string; project: string | null; agent: string | null; automation: string | null;
	provider: string | null; route: string | null; model: string | null; role: string | null; input: number; output: number; cache_read: number; cache_write: number; usd: number | null; plan: number;
};

/** Tools that write a file at `path` (pi's and Claude Code's names). */
const FILE_TOOLS = new Set(["edit", "write", "multi_edit", "Edit", "Write", "MultiEdit"]);
const COLUMNS = "id, at, place, kind, source, source_kind, project, agent, automation, provider, route, model, role, input, output, cache_read, cache_write, usd, plan";
const DAY = 86_400_000;

/** Names for what rows point at, read when asked (an agent renamed since keeps its new name). */
export type LedgerNames = { agent?(id: string): string | undefined; automation?(id: string): string | undefined };

export class UsageLedger {
	private readonly db: DatabaseSync;
	private readonly insertRow: StatementSync;
	/** Whether requests through a provider are billed to a subscription (shown as tokens, OV4). */
	planOf: (provider: string, usd: number) => boolean = () => false;
	/** What a cost's scope is (a conversation's or an agent's id); unknown and "app" are Piopio's own work. */
	resolve: (scope: string) => LedgerSource | undefined = () => undefined;
	/** After a write that added or changed rows (Piopio's monthly budget checks itself). */
	onWrite: () => void = () => {};

	constructor(file = ":memory:") {
		this.db = new DatabaseSync(file);
		this.db.exec(SQLITE_PRAGMAS);
		this.db.exec(`
			CREATE TABLE IF NOT EXISTS usage_ledger (
				id TEXT PRIMARY KEY, at TEXT NOT NULL, place TEXT NOT NULL, kind TEXT NOT NULL, source TEXT NOT NULL, source_kind TEXT NOT NULL,
				project TEXT, agent TEXT, automation TEXT, provider TEXT, route TEXT, model TEXT, role TEXT,
				input INTEGER NOT NULL, output INTEGER NOT NULL, cache_read INTEGER NOT NULL, cache_write INTEGER NOT NULL, usd REAL, plan INTEGER NOT NULL
			);
			CREATE INDEX IF NOT EXISTS usage_ledger_at ON usage_ledger (at);
			CREATE TABLE IF NOT EXISTS ledger_sources (key TEXT PRIMARY KEY, ref TEXT NOT NULL, title TEXT NOT NULL);
			CREATE TABLE IF NOT EXISTS ledger_synced (key TEXT PRIMARY KEY, mark TEXT NOT NULL);
			CREATE TABLE IF NOT EXISTS ledger_meta (key TEXT PRIMARY KEY, value TEXT NOT NULL);
			-- What sessions show, for Overview › Activity (34 §7): your messages, tool calls, approvals, errors, compactions,
			-- checkpoints, undone results. Refs, names and numbers; no content.
			CREATE TABLE IF NOT EXISTS activity (id TEXT PRIMARY KEY, at TEXT NOT NULL, source TEXT NOT NULL, kind TEXT NOT NULL, name TEXT, status TEXT, value REAL);
			CREATE INDEX IF NOT EXISTS activity_at ON activity (at);
		`);
		// The activity index came after the ledger (2026-11-23), and files written came with v2: read every
		// conversation again once to fill it.
		if (!this.meta("activity_v2")) {
			this.db.exec("DELETE FROM ledger_synced");
			this.setMeta("activity_v2", new Date().toISOString());
		}
		// Same request, same id: a live answer and the same answer read back are one request. A price that arrived later
		// (Claude Code's cost comes with the turn's result, after its last answer) replaces a missing or smaller one.
		this.insertRow = this.db.prepare(
			`INSERT INTO usage_ledger (${COLUMNS}) VALUES (${COLUMNS.split(", ").map(() => "?").join(", ")})
			ON CONFLICT(id) DO UPDATE SET usd = excluded.usd, plan = excluded.plan WHERE excluded.usd IS NOT NULL AND (usage_ledger.usd IS NULL OR excluded.usd > usage_ledger.usd)`,
		);
	}

	// ── Writing ──

	/** Renames a container's sources ("<id>", and an agent's "<id>/<conversation>"), as a deleted one keeps its name. */
	retitle(container: string, title: string): void {
		this.db.prepare("UPDATE ledger_sources SET title = ? WHERE key = ? OR key LIKE ?").run(title, container, `${container}/%`);
	}

	/** Records every finished answer in `items` that reports usage. Returns how many were new. */
	recordItems(source: LedgerSource, items: readonly TimelineItem[], fromFile = false): number {
		if (!fromFile) this.recordActivity(source, items);
		const answers = items.filter((i): i is AssistantItem => i.kind === "assistant" && i.status !== "streaming" && Boolean(i.usage));
		this.db.prepare("INSERT INTO ledger_sources (key, ref, title) VALUES (?, ?, ?) ON CONFLICT(key) DO UPDATE SET ref = excluded.ref, title = excluded.title").run(source.key, JSON.stringify(source.ref), source.title);
		if (!answers.length) return 0;
		let added = 0;
		this.transaction(() => {
			for (const item of answers) if (this.recordAnswer(source, item, fromFile)) added++;
		});
		if (added) this.onWrite();
		return added;
	}

	/** What a session shows, as Activity counts it (idempotent by item: a tool that ends updates its row). */
	recordActivity(source: LedgerSource, items: readonly TimelineItem[]): void {
		const rows: [string, string, string, string | null, string | null, number | null][] = [];
		const add = (id: string, at: string, kind: string, name?: string, status?: string, value?: number) => rows.push([`${source.container}#${id}`, at, kind, name ?? null, status ?? null, value ?? null]);
		const tool = (t: Extract<TimelineItem, { kind: "tool" }>) => {
			if (t.status === "running" || t.status === "pending_approval") return;
			add(t.id, t.at, "tool", t.tool, t.status, t.durationMs);
			// A file it wrote (Build's edit and write): its path, to count files changed (34 §7).
			const args = t.args as { path?: unknown; file_path?: unknown } | undefined;
			const path = typeof args?.path === "string" ? args.path : typeof args?.file_path === "string" ? args.file_path : undefined;
			if (path && t.status === "done" && FILE_TOOLS.has(t.tool)) add(`${t.id}#file`, t.at, "file", path);
		};
		for (const item of items) {
			switch (item.kind) {
				case "user": add(item.id, item.at, "message"); break;
				case "assistant": if (item.status === "error") add(item.id, item.at, "error", item.errorKind ?? "other"); break;
				case "tool": tool(item); break;
				case "steps": for (const t of item.tools) tool(t); break;
				case "approval": if (item.status !== "pending") add(item.id, item.at, "approval", item.tool, item.status); break;
				case "compaction": add(item.id, item.at, "compaction"); break;
				case "checkpoint": add(item.id, item.at, "checkpoint", undefined, undefined, item.files ?? 0); break;
				case "result": if (item.undo?.status === "undone") add(item.id, item.at, "undone"); break;
			}
		}
		if (!rows.length) return;
		const insert = this.db.prepare("INSERT INTO activity (id, at, source, kind, name, status, value) VALUES (?, ?, ?, ?, ?, ?, ?) ON CONFLICT(id) DO UPDATE SET status = excluded.status, value = excluded.value, name = excluded.name");
		this.transaction(() => {
			for (const [id, at, kind, name, status, value] of rows) insert.run(id, at, source.key, kind, name, status, value);
		});
	}

	/** Activity rows in [from, to): kind, name, status and value, for counting. */
	activityRows(from: Date, to: Date): { at: string; source: string; kind: string; name: string | null; status: string | null; value: number | null }[] {
		return this.db.prepare("SELECT at, source, kind, name, status, value FROM activity WHERE at >= ? AND at < ?").all(from.toISOString(), to.toISOString()) as never;
	}

	/** How much happened each local day since `from`: your messages plus Piopio's requests. */
	perDay(from: Date, to: Date): Map<string, number> {
		const out = new Map<string, number>();
		const add = (at: string) => {
			const d = new Date(at);
			const key = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}-${String(d.getDate()).padStart(2, "0")}`;
			out.set(key, (out.get(key) ?? 0) + 1);
		};
		for (const r of this.db.prepare("SELECT at FROM activity WHERE kind = 'message' AND at >= ? AND at < ?").all(from.toISOString(), to.toISOString()) as { at: string }[]) add(r.at);
		for (const r of this.db.prepare("SELECT at FROM usage_ledger WHERE at >= ? AND at < ?").all(from.toISOString(), to.toISOString()) as { at: string }[]) add(r.at);
		return out;
	}

	/** The first thing the ledger or the activity index knows of. */
	firstAt(): string | undefined {
		const a = this.since();
		const b = (this.db.prepare("SELECT MIN(at) at FROM activity").get() as { at: string | null } | undefined)?.at ?? undefined;
		return a && b ? (a < b ? a : b) : (a ?? b);
	}

	private recordAnswer(source: LedgerSource, item: AssistantItem, fromFile: boolean): boolean {
		const u = item.usage!;
		const tokens = u.inputTokens + u.outputTokens + u.cacheReadTokens + u.cacheWriteTokens;
		// An answer that cost nothing and used nothing (a stopped one, the faux model's) isn't a request worth a row.
		if (tokens === 0 && !(u.costUsd > 0)) return false;
		const [provider, ...rest] = (item.model ?? "").split("/");
		const plan = provider ? this.planOf(provider, u.costUsd) : false;
		const tokens4 = `${u.inputTokens}.${u.outputTokens}.${u.cacheReadTokens}.${u.cacheWriteTokens}`;
		// The same request as a row from the other kind (shown vs read from the file): only its price may improve.
		const twin = this.db
			.prepare(`SELECT id FROM usage_ledger WHERE id LIKE ? ESCAPE '\\' AND kind = 'turn' AND ${fromFile ? "1" : "id LIKE ? ESCAPE '\\'"} AND coalesce(model, '') = ? AND input = ? AND output = ? AND cache_read = ? AND cache_write = ? LIMIT 1`)
			.get(...[`${likeEscape(source.container)}#%`, ...(fromFile ? [] : [`${likeEscape(source.container)}#file#%`]), rest.length ? item.model! : "", u.inputTokens, u.outputTokens, u.cacheReadTokens, u.cacheWriteTokens]) as { id: string } | undefined;
		return this.insert({
			id: twin?.id ?? (fromFile ? `${source.container}#file#${item.model ?? ""}#${tokens4}` : `${source.container}#${item.id}#${tokens4}`),
			at: item.at,
			place: source.place,
			kind: "turn",
			source: source.key,
			sourceKind: source.sourceKind,
			...(source.project ? { project: source.project } : {}),
			...(source.agent ? { agent: source.agent } : {}),
			...(source.automation ? { automation: source.automation } : {}),
			...(provider ? { provider } : {}),
			...(rest.length ? { model: item.model! } : {}),
			input: u.inputTokens,
			output: u.outputTokens,
			cacheRead: u.cacheReadTokens,
			cacheWrite: u.cacheWriteTokens,
			// pi reports $0 for a model it has no price for: that's unknown, not free (unless a plan pays for it).
			usd: u.costUsd > 0 || plan ? u.costUsd : null,
			plan,
		});
	}

	/**
	 * A paid request outside the conversation harness (a utility model, web search, embeddings), as it happens. `scope`
	 * is the conversation's or agent's id it counts toward ("app": Piopio's own work). A price that's missing, negative or
	 * not a number is stored as unknown, never as $0.
	 */
	recordCost(kind: CostKind, model: string, usd: number | undefined, scope = "app"): void {
		this.recordExtra({ at: new Date().toISOString(), scope, kind, model, usd: typeof usd === "number" && Number.isFinite(usd) && usd >= 0 ? usd : null });
	}

	/**
	 * The requests outside the turns of one conversation or agent (`scope`, its id: its own rows, and an agent's from any
	 * of its conversations), or of everything: what Cost shows. Unknown prices are counted, not added.
	 */
	costSummary(scope?: string): CostSummary {
		const where = scope ? "AND (source = ? OR agent = ?)" : "";
		const rows = this.db.prepare(`SELECT kind, COUNT(*) calls, SUM(usd) usd, SUM(CASE WHEN usd IS NULL THEN 1 ELSE 0 END) unknown FROM usage_ledger WHERE kind != 'turn' ${where} GROUP BY kind`).all(...(scope ? [scope, scope] : [])) as { kind: string; calls: number; usd: number | null; unknown: number }[];
		return {
			scope: scope ?? "app",
			knownUsd: rows.reduce((sum, row) => sum + (row.usd ?? 0), 0),
			unknownCalls: rows.reduce((sum, row) => sum + row.unknown, 0),
			calls: rows.reduce((sum, row) => sum + row.calls, 0),
			// The names Cost has always shown ("embeddings", not the ledger's "embedding").
			breakdown: rows.map((row) => ({ kind: row.kind === "embedding" ? "embeddings" : row.kind, calls: row.calls, knownUsd: row.usd ?? 0, unknownCalls: row.unknown })),
		};
	}

	/** Known USD of `scope`'s requests outside the turns in `month` ("YYYY-MM", UTC), for an agent's budget. */
	costMonthUsd(scope: string, month: string): number {
		// A range on `at` (ISO times sort as text), so the index answers it.
		const [y, m] = month.split("-").map(Number) as [number, number];
		const next = m === 12 ? `${y + 1}-01` : `${y}-${String(m + 1).padStart(2, "0")}`;
		const row = this.db.prepare("SELECT SUM(usd) usd FROM usage_ledger WHERE kind != 'turn' AND (source = ? OR agent = ?) AND at >= ? AND at < ?").get(scope, scope, month, next) as { usd: number | null } | undefined;
		return row?.usd ?? 0;
	}

	/** A cost's row, under `id` (a generated one as it happens; tests give their own). */
	recordExtra(row: { at: string; scope: string; kind: string; model: string; usd: number | null }, id = `extra#${row.at}#${Math.random().toString(36).slice(2, 10)}`): boolean {
		const source = row.scope === "app" ? undefined : this.resolve(row.scope);
		const kind: LedgerKind = row.kind === "web_search" ? "web_search" : row.kind === "embeddings" ? "embedding" : "utility";
		// Web search goes through OpenRouter; utility models are "<provider>/<id>".
		const provider = kind === "web_search" ? "openrouter" : row.model.includes("/") ? row.model.split("/")[0] : undefined;
		return this.insert({
			id,
			at: row.at,
			place: source?.place ?? "mac",
			kind,
			source: source?.key ?? (row.scope === "app" ? "app" : row.scope),
			sourceKind: source ? source.sourceKind : "app",
			...(source?.project ? { project: source.project } : {}),
			...(source?.agent ? { agent: source.agent } : {}),
			...(source?.automation ? { automation: source.automation } : {}),
			...(provider ? { provider } : {}),
			model: row.model,
			role: kind === "utility" ? "utility" : kind,
			input: 0,
			output: 0,
			cacheRead: 0,
			cacheWrite: 0,
			usd: row.usd,
			plan: false,
		});
	}

	private insert(r: LedgerRow): boolean {
		if (!this.db.isTransaction) queueMicrotask(() => this.onWrite());
		const changes = this.insertRow.run(r.id, r.at, r.place, r.kind, r.source, r.sourceKind, r.project ?? null, r.agent ?? null, r.automation ?? null, r.provider ?? null, r.route ?? null, r.model ?? null, r.role ?? null, r.input, r.output, r.cacheRead, r.cacheWrite, r.usd, r.plan ? 1 : 0).changes;
		return Number(changes) > 0;
	}

	/** Backfill bookkeeping: a conversation read up to `mark` (its updatedAt) needn't be read again until it changes. */
	synced(key: string): string | undefined {
		return (this.db.prepare("SELECT mark FROM ledger_synced WHERE key = ?").get(key) as { mark: string } | undefined)?.mark;
	}
	markSynced(key: string, mark: string): void {
		this.db.prepare("INSERT INTO ledger_synced (key, mark) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET mark = excluded.mark").run(key, mark);
	}

	meta(key: string): string | undefined {
		return (this.db.prepare("SELECT value FROM ledger_meta WHERE key = ?").get(key) as { value: string } | undefined)?.value;
	}
	setMeta(key: string, value: string): void {
		this.db.prepare("INSERT INTO ledger_meta (key, value) VALUES (?, ?) ON CONFLICT(key) DO UPDATE SET value = excluded.value").run(key, value);
	}

	// ── Reading ──

	rows(from: Date, to: Date): LedgerRow[] {
		const stored = this.db.prepare(`SELECT ${COLUMNS} FROM usage_ledger WHERE at >= ? AND at < ? ORDER BY at`).all(from.toISOString(), to.toISOString()) as Stored[];
		return stored.map(fromStored);
	}

	since(): string | undefined {
		return (this.db.prepare("SELECT MIN(at) at FROM usage_ledger").get() as { at: string | null } | undefined)?.at ?? undefined;
	}

	/** Known USD in the local month of `now`, everything on this Mac and in the cloud (plans excluded). */
	monthKnownUsd(now = new Date()): number {
		const { from, to } = rangeBounds("month", now);
		const row = this.db.prepare("SELECT SUM(usd) usd FROM usage_ledger WHERE at >= ? AND at < ? AND plan = 0").get(from.toISOString(), to.toISOString()) as { usd: number | null } | undefined;
		return row?.usd ?? 0;
	}

	/** Known USD for an agent (or a conversation) in a local month, for budgets that read the ledger. */
	monthUsd(filter: { agent?: string; source?: string }, now = new Date()): number {
		const { from, to } = rangeBounds("month", now);
		const rows = this.rows(from, to).filter((r) => (!filter.agent || r.agent === filter.agent) && (!filter.source || r.source === filter.source));
		return rows.reduce((n, r) => n + (r.plan ? 0 : (r.usd ?? 0)), 0);
	}

	spend(params: { range: SpendRange; groupBy?: SpendGroupBy; filter?: { agent?: string; automation?: string; place?: string } }, names: LedgerNames = {}, now = new Date()): SpendResult {
		const groupBy = params.groupBy ?? "what";
		const { from, to } = rangeBounds(params.range, now);
		const rows = this.rows(from, to).filter((r) => matches(r, params.filter));
		const money = rows.filter((r) => !r.plan);
		const knownUsd = sum(money, (r) => r.usd ?? 0);
		const tokens = { input: sum(rows, (r) => r.input), output: sum(rows, (r) => r.output), cacheRead: sum(rows, (r) => r.cacheRead), cacheWrite: sum(rows, (r) => r.cacheWrite) };
		const byMonth = params.range === "12m";
		const days = buckets(from, to, byMonth).map((day) => ({ day, macUsd: 0, cloudUsd: 0, calls: 0, unknownCalls: 0, top: [] as { label: string; usd: number }[] }));
		const index = new Map(days.map((d, i) => [d.day, i]));
		const perDay = new Map<string, Map<string, { label: string; usd: number }>>();
		for (const r of rows) {
			const day = bucketOf(new Date(r.at), byMonth);
			const d = days[index.get(day) ?? -1];
			if (!d) continue;
			d.calls++;
			if (!r.plan && r.usd === null) d.unknownCalls++;
			const usd = r.plan ? 0 : (r.usd ?? 0);
			if (r.place === "mac") d.macUsd += usd;
			else d.cloudUsd += usd;
			if (!usd) continue;
			const g = whatGroup(r, names);
			const spenders = perDay.get(day) ?? new Map();
			perDay.set(day, spenders);
			const s = spenders.get(g.id) ?? { label: g.label, usd: 0 };
			s.usd += usd;
			spenders.set(g.id, s);
		}
		for (const d of days) d.top = [...(perDay.get(d.day)?.values() ?? [])].sort((a, b) => b.usd - a.usd).slice(0, 3);
		const forecastUsd = params.range === "month" ? forecast(knownUsd, now) : undefined;
		const since = this.since();
		return {
			range: params.range,
			from: from.toISOString(),
			to: to.toISOString(),
			knownUsd,
			calls: rows.length,
			unknownCalls: money.filter((r) => r.usd === null).length,
			planCalls: rows.length - money.length,
			planTokens: sum(rows.filter((r) => r.plan), (r) => r.input + r.output + r.cacheRead + r.cacheWrite),
			tokens,
			...(forecastUsd !== undefined ? { forecastUsd } : {}),
			days,
			groupBy,
			groups: this.group(rows, groupBy, names, knownUsd),
			suggestions: [],
			...(since ? { since } : {}),
		};
	}

	/** What one group counts, by conversation, costliest first. */
	items(params: { range: SpendRange; groupBy: SpendGroupBy; group: string }, names: LedgerNames = {}, now = new Date()): SpendItem[] {
		const { from, to } = rangeBounds(params.range, now);
		const rows = this.rows(from, to).filter((r) => groupOf(r, params.groupBy, names).id === params.group);
		const by = new Map<string, LedgerRow[]>();
		for (const r of rows) by.set(r.source, [...(by.get(r.source) ?? []), r]);
		const sources = new Map((this.db.prepare("SELECT key, ref, title FROM ledger_sources").all() as { key: string; ref: string; title: string }[]).map((s) => [s.key, s]));
		const out: SpendItem[] = [];
		for (const [key, list] of by) {
			const s = sources.get(key);
			if (!s) continue;
			const money = list.filter((r) => !r.plan);
			out.push({
				ref: JSON.parse(s.ref) as ContainerRef,
				title: s.title,
				usd: sum(money, (r) => r.usd ?? 0),
				calls: list.length,
				unknownCalls: money.filter((r) => r.usd === null).length,
				plan: money.length === 0,
				tokens: sum(list, (r) => r.input + r.output + r.cacheRead + r.cacheWrite),
				lastAt: list.at(-1)!.at,
			});
		}
		return out.sort((a, b) => b.usd - a.usd || b.tokens - a.tokens);
	}

	/** The range as CSV, one row per request (34 §8.3). */
	csv(range: SpendRange, now = new Date()): { csv: string; rows: number } {
		const { from, to } = rangeBounds(range, now);
		const rows = this.rows(from, to);
		const head = ["at", "place", "kind", "conversation", "project", "agent", "automation", "provider", "model", "role", "input", "output", "cache_read", "cache_write", "usd", "plan"];
		const lines = rows.map((r) => [r.at, r.place, r.kind, r.source, r.project ?? "", r.agent ?? "", r.automation ?? "", r.provider ?? "", r.model ?? "", r.role ?? "", r.input, r.output, r.cacheRead, r.cacheWrite, r.usd ?? "", r.plan ? "true" : "false"].map(cell).join(","));
		return { csv: [head.join(","), ...lines].join("\n") + "\n", rows: rows.length };
	}

	private group(rows: readonly LedgerRow[], groupBy: SpendGroupBy, names: LedgerNames, total: number): SpendGroup[] {
		const groups = new Map<string, SpendGroup & { money: number }>();
		for (const r of rows) {
			const g = groupOf(r, groupBy, names);
			const cur = groups.get(g.id) ?? { ...g, usd: 0, calls: 0, unknownCalls: 0, plan: true, tokens: 0, share: 0, money: 0 };
			cur.calls++;
			cur.tokens += r.input + r.output + r.cacheRead + r.cacheWrite;
			if (!r.plan) {
				cur.plan = false;
				cur.money++;
				if (r.usd === null) cur.unknownCalls++;
				else cur.usd += r.usd;
			}
			groups.set(g.id, cur);
		}
		return [...groups.values()]
			.map(({ money: _, ...g }) => ({ ...g, share: total > 0 ? g.usd / total : 0 }))
			.sort((a, b) => b.usd - a.usd || b.tokens - a.tokens);
	}

	private transaction(body: () => void): void {
		if (this.db.isTransaction) return body();
		this.db.exec("BEGIN");
		try {
			body();
			this.db.exec("COMMIT");
		} catch (error) {
			this.db.exec("ROLLBACK");
			throw error;
		}
	}

	close(): void {
		this.db.close();
	}
}

/** Budgets as Overview lists them (34 §5.4): what's spent of what's allowed, and when it starts again. */
export function monthlyBudget(id: string, name: string, spentUsd: number, limitUsd: number, ref: ContainerRef, now = new Date()): Budget {
	const next = new Date(now.getFullYear(), now.getMonth() + 1, 1);
	return { id: `agent:${id}`, kind: "agent", name, spentUsd, limitUsd, period: "month", resets: next.toISOString(), ref };
}

// ── Ranges and groups ──

/** A range's local bounds: [from, to). */
export function rangeBounds(range: SpendRange, now = new Date()): { from: Date; to: Date } {
	const y = now.getFullYear();
	const m = now.getMonth();
	const today = new Date(y, m, now.getDate());
	const tomorrow = new Date(y, m, now.getDate() + 1);
	switch (range) {
		case "today": return { from: today, to: tomorrow };
		case "7d": return { from: new Date(y, m, now.getDate() - 6), to: tomorrow };
		case "month": return { from: new Date(y, m, 1), to: new Date(y, m + 1, 1) };
		case "last_month": return { from: new Date(y, m - 1, 1), to: new Date(y, m, 1) };
		case "12m": return { from: new Date(y, m - 11, 1), to: new Date(y, m + 1, 1) };
	}
}

function bucketOf(d: Date, byMonth: boolean): string {
	const ym = `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
	return byMonth ? ym : `${ym}-${String(d.getDate()).padStart(2, "0")}`;
}

function buckets(from: Date, to: Date, byMonth: boolean): string[] {
	const out: string[] = [];
	for (let d = new Date(from); d < to; d = byMonth ? new Date(d.getFullYear(), d.getMonth() + 1, 1) : new Date(d.getFullYear(), d.getMonth(), d.getDate() + 1)) out.push(bucketOf(d, byMonth));
	return out;
}

/** Straight-line from the days so far; hidden before day 5, when a day or two would say too much. */
function forecast(knownUsd: number, now: Date): number | undefined {
	const day = now.getDate();
	if (day < 5) return undefined;
	const length = new Date(now.getFullYear(), now.getMonth() + 1, 0).getDate();
	const elapsed = (now.getTime() - new Date(now.getFullYear(), now.getMonth(), 1).getTime()) / DAY;
	return elapsed > 0 ? (knownUsd / elapsed) * length : undefined;
}

function matches(r: LedgerRow, filter?: { agent?: string; automation?: string; place?: string }): boolean {
	if (!filter) return true;
	if (filter.agent && r.agent !== filter.agent) return false;
	if (filter.automation && r.automation !== filter.automation) return false;
	if (filter.place && (filter.place === "cloud" ? r.place === "mac" : r.place !== filter.place)) return false;
	return true;
}

function whatGroup(r: LedgerRow, names: LedgerNames): { id: string; label: string; ref?: ContainerRef } {
	if (r.automation) return { id: `automation:${r.automation}`, label: names.automation?.(r.automation) ?? "Automation" };
	if (r.agent) return { id: `agent:${r.agent}`, label: names.agent?.(r.agent) ?? "Agent", ref: { kind: "agent", id: r.agent } };
	if (r.sourceKind === "app") return { id: "piopio", label: "Piopio's own work" };
	if (r.sourceKind === "build") return { id: "build", label: "Build sessions" };
	return { id: "conversations", label: "Conversations" };
}

function groupOf(r: LedgerRow, groupBy: SpendGroupBy, names: LedgerNames): { id: string; label: string; ref?: ContainerRef } {
	switch (groupBy) {
		case "what": return whatGroup(r, names);
		case "model": {
			const model = r.model ?? "unknown";
			return { id: model, label: r.model ? modelLabel(r.model) : "Unknown model" };
		}
		case "provider": return { id: r.provider ?? "unknown", label: r.provider ?? "Unknown provider" };
		case "project": return r.project ? { id: r.project, label: basename(r.project) } : { id: "none", label: "No project" };
		case "where": return r.place === "mac" ? { id: "mac", label: "This Mac" } : { id: r.place, label: "Cloud" };
	}
}

/** "openrouter/anthropic/claude-sonnet-5.5" → "anthropic/claude-sonnet-5.5 · openrouter". */
function modelLabel(model: string): string {
	const [provider, ...rest] = model.split("/");
	return rest.length ? `${rest.join("/")} · ${provider}` : model;
}

function fromStored(s: Stored): LedgerRow {
	return {
		id: s.id, at: s.at, place: s.place, kind: s.kind as LedgerKind, source: s.source, sourceKind: s.source_kind,
		...(s.project ? { project: s.project } : {}), ...(s.agent ? { agent: s.agent } : {}), ...(s.automation ? { automation: s.automation } : {}),
		...(s.provider ? { provider: s.provider } : {}), ...(s.route ? { route: s.route } : {}), ...(s.model ? { model: s.model } : {}), ...(s.role ? { role: s.role } : {}),
		input: s.input, output: s.output, cacheRead: s.cache_read, cacheWrite: s.cache_write, usd: s.usd, plan: s.plan === 1,
	};
}

/** For LIKE patterns ('\\' is the escape character in the statements that use it). */
const likeEscape = (s: string) => s.replace(/[\\%_]/g, (c) => `\\${c}`);
const sum = <T>(list: readonly T[], f: (x: T) => number) => list.reduce((n, x) => n + f(x), 0);
const cell = (v: string | number) => (typeof v === "string" && /[",\n]/.test(v) ? `"${v.replace(/"/g, '""')}"` : String(v));
