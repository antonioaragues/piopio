/**
 * Cheaper next time (docs/spec/34 §5.5, decision OV7): at most three suggestions, each with the number it's based on
 * and one thing to do. None without a number behind it.
 */
import type { ModelInfo, SpendSuggestion } from "@piopio/protocol";
import type { LedgerNames, LedgerRow } from "./ledger.js";

type Pricing = ModelInfo["pricing"];

export type SuggestContext = {
	/** Available models with their prices (USD per million tokens). */
	models: readonly ModelInfo[];
	names: LedgerNames;
	/** The on-device model can run Piopio's own work here, and it isn't already chosen. */
	onDeviceOffer: boolean;
	/** "this month", "these 7 days"… */
	rangeLabel: string;
};

/** Below this, a saving isn't worth a line. */
const MIN_SAVING = 0.5;
const LIGHT = ["haiku", "mini", "flash", "lite", "nano", "small"];

/** A model's name from the list, or its id without the provider ("anthropic/claude-sonnet-5.5"). */
const nameOf = (model: string, byKey: ReadonlyMap<string, ModelInfo>) => byKey.get(model)?.name ?? model.split("/").slice(1).join("/") ?? model;
const money = (usd: number) => (usd < 0.1 ? `$${usd.toFixed(3)}` : `$${usd.toFixed(2)}`);
const key = (m: ModelInfo) => `${m.provider}/${m.id}`;
const cost = (r: LedgerRow, p: Pricing) => (r.input * p.input + r.output * p.output + r.cacheRead * p.cacheRead + r.cacheWrite * p.cacheWrite) / 1e6;

/** The same maker's light model ("anthropic/claude-haiku-5.5" for an Opus or a Sonnet), the newest-priced one below it. */
export function lighterModel(model: string, models: readonly ModelInfo[]): ModelInfo | undefined {
	const current = models.find((m) => key(m) === model);
	if (!current || !(current.pricing.input > 0)) return undefined;
	const vendor = current.id.includes("/") ? current.id.split("/")[0] : "";
	const name = current.id.toLowerCase();
	if (LIGHT.some((w) => name.includes(w))) return undefined;
	return models
		.filter((m) => m.provider === current.provider && (m.id.includes("/") ? m.id.split("/")[0] : "") === vendor && m.id !== current.id)
		.filter((m) => LIGHT.some((w) => m.id.toLowerCase().includes(w)) && m.pricing.input > 0 && m.pricing.input < current.pricing.input && !m.id.includes(":"))
		.sort((a, b) => b.pricing.input - a.pricing.input)[0];
}

export function suggestions(rows: readonly LedgerRow[], ctx: SuggestContext): SpendSuggestion[] {
	const out: SpendSuggestion[] = [];
	const byKey = new Map(ctx.models.map((m) => [key(m), m]));
	const known = rows.filter((r) => !r.plan && r.usd !== null);

	// 1. An automation or an agent on a heavy model, where the same maker's light one would have cost much less.
	const owners = new Map<string, LedgerRow[]>();
	for (const r of known) {
		if (r.kind !== "turn" || !r.model) continue;
		const owner = r.automation ? `automation:${r.automation}` : r.agent ? `agent:${r.agent}` : undefined;
		if (owner) owners.set(owner, [...(owners.get(owner) ?? []), r]);
	}
	for (const [owner, list] of owners) {
		const byModel = new Map<string, LedgerRow[]>();
		for (const r of list) byModel.set(r.model!, [...(byModel.get(r.model!) ?? []), r]);
		const [model, used] = [...byModel].sort((a, b) => sum(b[1]) - sum(a[1]))[0]!;
		const spent = sum(used);
		const lighter = lighterModel(model, ctx.models);
		if (!lighter) continue;
		const would = used.reduce((n, r) => n + cost(r, lighter.pricing), 0);
		if (spent - would < MIN_SAVING || would > spent / 2) continue;
		const [kind, id] = owner.split(":") as ["automation" | "agent", string];
		const label = (kind === "automation" ? ctx.names.automation?.(id) : ctx.names.agent?.(id)) ?? (kind === "automation" ? "An automation" : "An agent");
		out.push({
			id: `lighter:${owner}`,
			text: `${label} spent ${money(spent)} on ${nameOf(model, byKey)} ${ctx.rangeLabel}; ${lighter.name} would have been about ${money(would)}`,
			savingUsd: spent - would,
			action: { kind, id, label: "Change model" },
		});
	}

	// 2. What reading from the cache saved (information only).
	let cached = 0;
	for (const r of known) {
		const p = r.cacheRead && r.model ? byKey.get(r.model)?.pricing : undefined;
		if (p && p.input > p.cacheRead) cached += (r.cacheRead * (p.input - p.cacheRead)) / 1e6;
	}
	if (cached >= MIN_SAVING) out.push({ id: "cache", text: `Cache reads saved about ${money(cached)} ${ctx.rangeLabel}`, savingUsd: cached });

	// 3. Piopio's own work (titles, memory, the organizer) on a paid model, when the on-device one could do it.
	if (ctx.onDeviceOffer) {
		const own = known.filter((r) => r.role === "utility" && r.model !== "apple/on-device");
		const spent = sum(own);
		if (spent >= 0.1) {
			const model = own.sort((a, b) => (b.usd ?? 0) - (a.usd ?? 0))[0]?.model;
			out.push({
				id: "on_device",
				text: `Titles and memory used ${money(spent)} ${ctx.rangeLabel}${model ? ` on ${nameOf(model, byKey)}` : ""}; the on-device model would make them free`,
				savingUsd: spent,
				action: { kind: "on_device", label: "Use on-device" },
			});
		}
	}
	return out.sort((a, b) => b.savingUsd - a.savingUsd).slice(0, 3);
}

const sum = (list: readonly LedgerRow[]) => list.reduce((n, r) => n + (r.usd ?? 0), 0);
