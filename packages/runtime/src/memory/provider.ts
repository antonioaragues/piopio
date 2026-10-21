/**
 * Memory providers (docs/spec/07-shared-resources §5.1): what conversations learn, stored in banks and found again.
 * A bank is an isolated store: "about-me", one Space, one agent partition. Every record keeps its source, so the
 * app's memory views can show where each fact came from (01-product, principle 4).
 */

export type MemoryKind = "fact" | "message" | "experience" | "observation" | "opinion";

export type MemorySource = { ref?: string; itemId?: string; title?: string };

export type MemoryRecord = {
	id: string;
	bank: string;
	text: string;
	kind: MemoryKind;
	/** Who wrote it: an agent's tool, the user, or the provider's own extraction. */
	createdBy: "agent" | "user" | "extraction";
	at: string;
	source?: MemorySource;
	tags?: string[];
	pinned?: boolean;
	/** The provider's own confidence (Hindsight opinions), 0–1. */
	confidence?: number;
};

export type MemoryHit = MemoryRecord & { score: number };

export type RetainInput = { content: string; kind?: MemoryKind; createdBy?: MemoryRecord["createdBy"]; source?: MemorySource; at?: string; tags?: string[]; pinned?: boolean };

export type MemoryEvent = { id: string; at: string; bank: string; action: "added" | "removed" | "updated"; recordId: string; text: string; tags?: string[]; by: MemoryRecord["createdBy"]; batch?: string };

/** What a provider can do beyond recall; the app shows "limited visibility" without `list`. */
export type MemoryCapabilities = { retain: boolean; list: boolean; forget: boolean; update: boolean; reflect: boolean; history: boolean };

export interface MemoryProvider {
	readonly id: string;
	readonly capabilities: MemoryCapabilities;
	/** Learns from a message or a run, or stores a fact. Returns the records it made (none when it extracts later). */
	retain(bank: string, input: RetainInput): Promise<MemoryRecord[]>;
	/** The most relevant records for `query`, packed into `budgetTokens` (about 4 characters a token). */
	recall(banks: readonly string[], query: string, options?: { budgetTokens?: number; kinds?: MemoryKind[]; limit?: number }): Promise<MemoryHit[]>;
	/** An answer reasoned over the bank (Hindsight's reflect). */
	reflect?(bank: string, question: string): Promise<{ answer: string; used: MemoryHit[] }>;
	/** Every record, newest first: the memory view. */
	list?(bank: string, options?: { cursor?: string; limit?: number; kinds?: MemoryKind[]; tag?: string }): Promise<{ records: MemoryRecord[]; cursor?: string }>;
	forget?(bank: string, id: string, by?: MemoryRecord["createdBy"]): Promise<void>;
	update?(bank: string, id: string, change: { text?: string; pinned?: boolean; tags?: string[] }, by?: MemoryRecord["createdBy"]): Promise<MemoryRecord>;
	/** Changes, newest first, grouped by `batch` when one write changed several records. */
	history?(bank: string, options?: { limit?: number }): Promise<MemoryEvent[]>;
	/** Pinned or pre-computed answers, cheap enough for every turn's system section. */
	standing?(bank: string): Promise<MemoryRecord[]>;
	close?(): Promise<void>;
}

/** Packs hits into a token budget, best first (about 4 characters a token). */
export function pack<T extends { text: string }>(hits: readonly T[], budgetTokens: number): T[] {
	const out: T[] = [];
	let chars = 0;
	for (const h of hits) {
		chars += h.text.length + 20;
		if (chars / 4 > budgetTokens && out.length) break;
		out.push(h);
	}
	return out;
}
