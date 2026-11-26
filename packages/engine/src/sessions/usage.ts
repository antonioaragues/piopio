/**
 * What conversations spent, for the usage ledger and Overview (docs/spec/34 §8.1): where each conversation's requests
 * belong (`source`), writing its finished answers in (`record`), reading past usage in (`backfill`), the names
 * Overview shows, and every budget Piopio has. Everything this needs from the conversations comes through
 * `UsageHost`, which Sessions implements; the rows themselves are the ledger's (ledger.ts).
 */
import type { Budget, ContainerRef, TimelineItem } from "@piopio/protocol";
import { DEFAULT_BUDGET, PIOPIO } from "../automations/model.js";
import type { Automations } from "../automations/service.js";
import type { LedgerSource, UsageLedger } from "../ledger.js";
import { TEMPORARY_TITLE, type CatalogEntry } from "./catalog-entry.js";

export interface UsageHost {
	entry(id: string): CatalogEntry | undefined;
	entries(): Iterable<CatalogEntry>;
	automations(): Automations | undefined;
	ledger(): UsageLedger;
	/** Reads a conversation into search (and through it the ledger): an agent's, a cloud agent's through the cloud. */
	indexContainer(entry: CatalogEntry): Promise<void>;
	/** Every answer a conversation's files paid for: all branches and what a compaction folded. */
	storedAnswers(entry: CatalogEntry): TimelineItem[];
	/** An open agent's answers, all of them (its views show a window); undefined when it isn't open. */
	agentAnswers(entry: CatalogEntry): Promise<TimelineItem[] | undefined>;
}

export class SessionUsage {
	constructor(private readonly host: UsageHost) {}

	/**
	 * Where a conversation's requests belong: its container (a session, or the agent: one pi-durable session, so its
	 * entry ids are unique across its conversations), and what it's part of. `entry.ref.id` may be search's key
	 * ("<agent>/<conversationId>"). A subagent's or side conversation's requests count where its parent's do.
	 */
	source(entry: CatalogEntry): LedgerSource {
		const key = entry.ref.id;
		const slash = key.indexOf("/");
		const container = slash < 0 ? key : key.slice(0, slash);
		const conversation = slash < 0 ? entry.ref.conversationId : key.slice(slash + 1);
		const own = this.host.entry(container) ?? { ...entry, ref: { ...entry.ref, id: container } };
		const ref: ContainerRef = conversation ? { kind: own.ref.kind, id: container, conversationId: conversation } : { kind: own.ref.kind, id: container };
		let root = own;
		for (let i = 0; i < 8; i++) {
			const up = root.parent?.id ?? root.side?.parent.id;
			const next = up ? this.host.entry(up) : undefined;
			if (!next) break;
			root = next;
		}
		const agent = own.ref.kind === "agent" ? container : undefined;
		const automation = agent
			? conversation?.startsWith("run:") ? this.host.automations()?.runOf({ agent, agentRun: conversation.slice(4) })?.run.automation : undefined
			: (this.host.automations()?.runOf({ conversation: container }) ?? this.host.automations()?.runOf({ conversation: root.ref.id }))?.run.automation;
		const project = root.helper?.project ?? root.projectPath ?? (root.ref.kind === "build" ? root.cwd : undefined);
		return {
			key,
			container,
			ref,
			// A temporary chat's title is made from its first message: the ledger, kept for good, has its spend only
			// (docs/spec/14 M4; re-audit 2026-11-25 V6). Keeping the chat names it on its next record.
			title: own.temporary || root.temporary ? TEMPORARY_TITLE : entry.title,
			sourceKind: root.ref.kind === "build" || root.helper ? "build" : own.ref.kind,
			...(project ? { project } : {}),
			...(agent ? { agent } : {}),
			...(automation ? { automation } : {}),
			place: own.cloud ? "cloud" : "mac",
		};
	}

	/** Writes the finished answers' usage into the ledger (idempotent: an answer read again isn't counted twice). */
	record(entry: CatalogEntry, all: readonly TimelineItem[], fromFile = false): void {
		// Only what's settled: a streaming answer or a running tool is written when it ends.
		const items = all.filter((i) => (i.kind === "assistant" ? i.status !== "streaming" : i.kind === "tool" ? i.status !== "running" && i.status !== "pending_approval" : i.kind !== "system" && i.kind !== "agent_msg"));
		if (!items.length) return;
		try {
			this.host.ledger().recordItems(this.source(entry), items, fromFile);
		} catch (error) {
			// Overview's numbers are never worth a failed turn.
			console.error(`usage ledger: ${error instanceof Error ? error.message : String(error)}`);
		}
	}

	private ledgerBackfill?: Promise<void>;

	/**
	 * Reads past usage into the ledger: every conversation that changed since it was last read (its updatedAt; an agent's also by its month's spend, since its runs don't touch the catalog). The first
	 * time it reads everything; after that, only what's new. Returns when done.
	 */
	backfill(): Promise<void> {
		this.ledgerBackfill ??= (async () => {
			const ledger = this.host.ledger();
			for (const entry of [...this.host.entries()]) {
				if (!this.host.entry(entry.ref.id)) continue;
				const mark = entry.ref.kind === "agent" ? `${entry.updatedAt}|${entry.agent?.status?.spendUsd ?? 0}` : entry.updatedAt;
				if (ledger.synced(entry.ref.id) === mark) continue;
				try {
					if (entry.ref.kind === "agent" && entry.cloud) {
						// Your cloud's agents (docs/spec/34 OV4): their conversations and runs, read through the cloud when it answers.
						const read = await Promise.race([this.host.indexContainer(entry).then(() => true), new Promise<false>((r) => setTimeout(() => r(false), 10_000).unref())]).catch(() => false);
						this.cloudLedger = read ? { ...this.cloudLedger, at: new Date().toISOString(), failed: false } : { ...this.cloudLedger, failed: true };
						if (read) ledger.markSynced(entry.ref.id, mark);
						continue;
					}
					await this.host.indexContainer(entry);
					// The whole file, open or not: branches you left and what a compaction folded were paid for too.
					if (entry.ref.kind === "thread" || entry.ref.kind === "build") this.record(entry, this.host.storedAnswers(entry), true);
					// An agent's views show a window of the latest entries; its answers are all in the harness.
					const answers = entry.ref.kind === "agent" ? await this.host.agentAnswers(entry) : undefined;
					if (answers) this.record(entry, answers);
					ledger.markSynced(entry.ref.id, mark);
				} catch {
					// Unreadable or missing files: tried again next time.
				}
			}
		})().finally(() => {
			this.ledgerBackfill = undefined;
		});
		return this.ledgerBackfill;
	}

	/** When the cloud's usage was last read, and whether the latest try failed (Spend says "Cloud usage up to 14:02"). */
	private cloudLedger: { at?: string; failed?: boolean } = {};

	/** Your cloud's usage is counted up to this time: set while the cloud didn't answer the latest read. */
	cloudAsOf(): string | undefined {
		if (!this.cloudLedger.failed) return undefined;
		return this.cloudLedger.at ?? this.host.ledger().since();
	}

	/** Names for Overview's rows: an agent's or an automation's current name. */
	names() {
		return {
			agent: (id: string) => this.host.entry(id)?.title,
			automation: (id: string) => this.host.automations()?.find(id)?.name,
		};
	}

	/** Every budget Piopio has (docs/spec/34 §5.4): each agent's month (AS3) and each automation's run (27). */
	budgets(now = new Date()): Budget[] {
		const out: Budget[] = [];
		const resets = new Date(now.getFullYear(), now.getMonth() + 1, 1).toISOString();
		for (const e of this.host.entries()) {
			const s = e.ref.kind === "agent" ? e.agent?.status : undefined;
			if (s?.budgetUsd === undefined) continue;
			out.push({ id: `agent:${e.ref.id}`, kind: "agent", name: e.title, spentUsd: s.spendUsd, limitUsd: s.budgetUsd, period: "month", resets, ref: { kind: "agent", id: e.ref.id } });
		}
		const automations = this.host.automations();
		for (const a of automations?.list() ?? []) {
			if (!a.enabled) continue;
			const limit = a.budgetPerRunUsd ?? (a.runsAs === PIOPIO ? DEFAULT_BUDGET.piopio : DEFAULT_BUDGET.agent);
			const last = automations!.lastRun(a.id);
			out.push({ id: `automation:${a.id}`, kind: "automation", name: a.name, spentUsd: last?.costUsd ?? 0, limitUsd: limit, period: "run", automation: a.id });
		}
		return out.sort((a, b) => b.spentUsd / b.limitUsd - a.spentUsd / a.limitUsd);
	}
}
