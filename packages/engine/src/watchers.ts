/**
 * Event routines on this Mac (docs/spec/19 S3): the watches agents set themselves with the `watch` tool. A folder watch
 * fires when a file appears or changes in that folder (not in its subfolders; hidden and partial downloads are
 * skipped); an email watch checks the owner's connected mail every few minutes for new messages from someone or with
 * words in the subject. Webhook watches need nothing here: the hooks endpoint (hooks.ts) fires them. Each fire is a run
 * in the agent (`fireWatch`), keyed so the same file version or message never runs twice.
 */
import { existsSync, readdirSync, readFileSync, statSync, watch, writeFileSync, type FSWatcher } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import type { Watch } from "@piopio/runtime";
import type { MailMessage } from "./connectors/types.js";

export type WatchHost = {
	/** Every agent's watches. */
	watches(): Promise<{ agentId: string; watches: Watch[] }[]>;
	fire(agentId: string, watchId: string, happened: string, key: string): Promise<void>;
	/** The owner's connected mailboxes (empty when none is connected). */
	mail(): { name: string; search(query: string, limit: number): Promise<MailMessage[]> }[];
	stateFile: string;
	log(line: string): void;
	/** Tests: how often mail is checked, and how long a folder settles before it's read. */
	mailEveryMs?: number;
	settleMs?: number;
};

type FolderWatch = { key: string; dir: string; watcher: FSWatcher; seen: Map<string, number>; timer?: NodeJS.Timeout };

const SKIP = /^\.|\.(crdownload|part|download|tmp)$|~$/i;

export class AgentWatchers {
	private folders = new Map<string, FolderWatch>();
	private mailTimer?: NodeJS.Timeout;
	private checking = false;
	private stopped = false;

	constructor(private readonly host: WatchHost) {}

	/** Starts what's new and stops what was removed. */
	async sync(): Promise<void> {
		if (this.stopped) return;
		const all = await this.host.watches();
		const wanted = new Set<string>();
		for (const { agentId, watches } of all) {
			for (const w of watches.filter((x) => x.on === "folder" && x.folder)) {
				const key = `${agentId}/${w.id}`;
				wanted.add(key);
				if (!this.folders.has(key)) this.watchFolder(key, agentId, w);
			}
		}
		for (const [key, f] of this.folders) {
			if (wanted.has(key)) continue;
			f.watcher.close();
			clearTimeout(f.timer);
			this.folders.delete(key);
		}
		const mail = all.some((a) => a.watches.some((w) => w.on === "email"));
		if (mail && !this.mailTimer) {
			this.mailTimer = setInterval(() => void this.checkMail(), this.host.mailEveryMs ?? 5 * 60_000);
			void this.checkMail();
		} else if (!mail && this.mailTimer) {
			clearInterval(this.mailTimer);
			this.mailTimer = undefined;
		}
	}

	stop(): void {
		this.stopped = true;
		for (const f of this.folders.values()) (f.watcher.close(), clearTimeout(f.timer));
		this.folders.clear();
		if (this.mailTimer) clearInterval(this.mailTimer);
	}

	// ── Folders ──

	private watchFolder(key: string, agentId: string, w: Watch): void {
		const dir = w.folder!.startsWith("~/") ? join(homedir(), w.folder!.slice(2)) : w.folder!;
		if (!existsSync(dir)) {
			this.host.log(`Routine ${w.id}: the folder ${dir} doesn't exist.`);
			return;
		}
		try {
			// What's already there doesn't count: only files that appear or change from now on.
			const seen = this.scan(dir);
			const watcher = watch(dir, () => {
				const f = this.folders.get(key);
				if (!f) return;
				clearTimeout(f.timer);
				f.timer = setTimeout(() => void this.settled(agentId, w, f), this.host.settleMs ?? 1500);
			});
			watcher.on("error", (error) => this.host.log(`Routine ${w.id}: ${error.message}`));
			this.folders.set(key, { key, dir, watcher, seen });
		} catch (error) {
			this.host.log(`Routine ${w.id}: can't watch ${dir}: ${(error as Error).message}`);
		}
	}

	private scan(dir: string): Map<string, number> {
		const out = new Map<string, number>();
		for (const name of readdirSync(dir)) {
			if (SKIP.test(name)) continue;
			try {
				const s = statSync(join(dir, name));
				if (s.isFile()) out.set(name, s.mtimeMs);
			} catch {
				// gone already
			}
		}
		return out;
	}

	private async settled(agentId: string, w: Watch, f: FolderWatch): Promise<void> {
		let now: Map<string, number>;
		try {
			now = this.scan(f.dir);
		} catch {
			return;
		}
		const changed = [...now].filter(([name, mtime]) => f.seen.get(name) !== mtime).map(([name, mtime]) => ({ name, mtime, existed: f.seen.has(name) }));
		f.seen = now;
		for (const { name, mtime, existed } of changed) {
			const path = join(f.dir, name);
			const happened = `A file ${existed ? "changed" : "appeared"} in ${f.dir}: ${path}`;
			await this.host.fire(agentId, w.id, happened, `${name}@${Math.round(mtime)}`).catch((error: unknown) => this.host.log(`Routine ${w.id}: ${(error as Error).message}`));
		}
	}

	// ── Mail ──

	private async checkMail(): Promise<void> {
		if (this.checking || this.stopped) return;
		this.checking = true;
		try {
			const all = (await this.host.watches()).flatMap((a) => a.watches.filter((w) => w.on === "email").map((w) => ({ agentId: a.agentId, w })));
			if (!all.length) return;
			const boxes = this.host.mail();
			if (!boxes.length) return;
			const state = this.readState();
			let messages: MailMessage[] = [];
			for (const box of boxes) messages = messages.concat(await box.search("", 25).catch(() => []));
			for (const { agentId, w } of all) {
				const since = state[w.id] ?? w.createdAt;
				const fresh = messages.filter((m) => m.received > since && matches(m, w)).sort((a, b) => a.received.localeCompare(b.received));
				for (const m of fresh) {
					const happened = `An email arrived.\nFrom: ${m.from}\nSubject: ${m.subject}\nReceived: ${m.received}\n\n${m.preview}`;
					await this.host.fire(agentId, w.id, happened, `mail:${m.id}`).catch((error: unknown) => this.host.log(`Routine ${w.id}: ${(error as Error).message}`));
					state[w.id] = m.received;
				}
			}
			this.writeState(state);
		} finally {
			this.checking = false;
		}
	}

	private readState(): Record<string, string> {
		try {
			return existsSync(this.host.stateFile) ? (JSON.parse(readFileSync(this.host.stateFile, "utf8")) as Record<string, string>) : {};
		} catch {
			return {};
		}
	}

	private writeState(state: Record<string, string>): void {
		writeFileSync(this.host.stateFile, JSON.stringify(state));
	}
}

/** From and subject are each a case-insensitive "contains"; a watch with both needs both. */
export function matches(m: Pick<MailMessage, "from" | "subject">, w: Pick<Watch, "from" | "subject">): boolean {
	const has = (field: string, part?: string) => !part || field.toLowerCase().includes(part.toLowerCase());
	return has(m.from, w.from) && has(m.subject, w.subject);
}
