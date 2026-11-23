/**
 * Piopio this month (docs/spec/34 §5.4, decision OV3): one budget over everything the usage ledger counts on this Mac,
 * off until you set it. At 80% it says so once; at 100% background work (automations) waits for your yes in Needs
 * you, and your own conversations keep going. Your yes is for one held run, or for the rest of the month.
 */
import type { PiopioBudget } from "@piopio/protocol";
import { readJsonFile, writeFileAtomic } from "./atomic.js";
import type { UsageLedger } from "./ledger.js";

type Stored = {
	limitUsd?: number;
	/** The month you said background work may go on past the budget ("2026-11"). */
	allowed?: string;
	/** What was said this month, so each level is said once. */
	said?: { month: string; near?: boolean; over?: boolean };
};

export type HeldRun = PiopioBudget["held"][number];

const monthOf = (d: Date) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, "0")}`;
const MONTH_NAMES = ["January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December"];

export class MonthBudget {
	private stored: Stored;
	private timer?: NodeJS.Timeout;
	private level?: PiopioBudget["state"];
	/** The level changed or something should be said: the app reads `stats.budgets` again. */
	onChange: (event: { notify?: string }) => void = () => {};
	/** Automation runs this budget holds (the automations service keeps them). */
	heldRuns: () => HeldRun[] = () => [];
	/** Runs what's held (after your yes, or a budget that no longer holds them). */
	releaseAll: () => void = () => {};

	constructor(
		private readonly file: string | undefined,
		private readonly ledger: UsageLedger,
		private readonly now: () => Date = () => new Date(),
	) {
		this.stored = file ? readJsonFile<Stored>(file, () => ({})) : {};
	}

	state(): PiopioBudget {
		const now = this.now();
		const month = monthOf(now);
		const spentUsd = this.ledger.monthKnownUsd(now);
		const limit = this.stored.limitUsd;
		const state: PiopioBudget["state"] =
			limit === undefined ? "off" : spentUsd >= limit ? (this.stored.allowed === month ? "allowed" : "over") : spentUsd >= 0.8 * limit ? "near" : "ok";
		return {
			month,
			...(limit !== undefined ? { limitUsd: limit } : {}),
			spentUsd,
			resets: new Date(now.getFullYear(), now.getMonth() + 1, 1).toISOString(),
			state,
			held: this.heldRuns(),
		};
	}

	/** Why background work waits now, or nothing. */
	holdReason(): string | undefined {
		const s = this.state();
		if (s.state !== "over") return undefined;
		return `Waiting: Piopio is past its $${s.limitUsd!.toFixed(2)} budget for ${MONTH_NAMES[this.now().getMonth()]} ($${s.spentUsd.toFixed(2)} spent)`;
	}

	/** Sets the budget, or turns it off (null). A budget that no longer holds anything lets what it held run. */
	set(limitUsd: number | null): PiopioBudget {
		if (limitUsd === null) delete this.stored.limitUsd;
		else if (!(limitUsd > 0)) throw new Error("A budget is more than $0.");
		else this.stored.limitUsd = limitUsd;
		// A new limit is a new start for what's said about it.
		delete this.stored.said;
		this.save();
		if (this.state().state !== "over") this.releaseAll();
		this.check(true);
		return this.state();
	}

	/** Your yes for the rest of the month: background work goes on, and what's held runs. */
	allowMonth(): PiopioBudget {
		this.stored.allowed = monthOf(this.now());
		this.save();
		this.releaseAll();
		this.check(true);
		return this.state();
	}

	/** After the ledger was written (debounced): a level crossed says so once a month. */
	written(): void {
		if (this.stored.limitUsd === undefined) return;
		clearTimeout(this.timer);
		this.timer = setTimeout(() => this.check(), 500);
		this.timer.unref?.();
	}

	/** A held run came or went: the app lists again. */
	heldChanged(): void {
		this.onChange({});
	}

	check(force = false): void {
		const s = this.state();
		const month = s.month;
		const said = this.stored.said?.month === month ? this.stored.said : { month };
		let notify: string | undefined;
		const limit = s.limitUsd !== undefined ? `$${s.limitUsd.toFixed(2)}` : "";
		if ((s.state === "over" || s.state === "allowed") && !said.over) {
			said.over = said.near = true;
			notify = `Piopio has spent ${limit}, its budget for ${MONTH_NAMES[Number(month.slice(5)) - 1]}. Automations wait for your OK; your conversations keep going.`;
		} else if (s.state === "near" && !said.near) {
			said.near = true;
			notify = `Piopio has spent $${s.spentUsd.toFixed(2)} of its ${limit} budget for ${MONTH_NAMES[Number(month.slice(5)) - 1]}.`;
		}
		if (notify) {
			this.stored.said = said;
			this.save();
		}
		if (notify || force || s.state !== this.level) this.onChange(notify ? { notify } : {});
		this.level = s.state;
	}

	close(): void {
		clearTimeout(this.timer);
	}

	private save(): void {
		if (this.file) writeFileAtomic(this.file, JSON.stringify(this.stored, null, "\t"));
	}
}
