/**
 * piopio-background: commands that keep running (docs/spec/05-build §9 TM4, roadmap PAR2). `bash` with
 * `background: true` (sandbox.ts) starts one here and returns at once; `process_output`, `process_stop` and
 * `process_list` read, stop and list them. Each runs in a process group of its own, so stopping it stops whatever it
 * started (`npm run dev` and the server under it). They never outlive the session.
 */
import { spawn, type ChildProcess } from "node:child_process";
import type { ExtensionFactory } from "@earendil-works/pi-coding-agent";
import { Type } from "typebox";

export type BackgroundProcess = {
	id: string;
	command: string;
	/** The activity label the agent gave it. */
	description?: string;
	cwd: string;
	status: "running" | "exited" | "stopped";
	exitCode?: number | null;
	startedAt: string;
	endedAt?: string;
	/** Local addresses it printed (a dev server's), first seen first. */
	urls: string[];
};

export const MAX_RUNNING = 8;
const KEEP_BYTES = 256 * 1024;
const LOCAL_URL = /\bhttps?:\/\/(?:localhost|127\.0\.0\.1|0\.0\.0\.0|\[::1\]|[a-z0-9-]+\.localhost)(?::\d+)?(?:\/[^\s'"`<>)\]]*)?/gi;
// biome-ignore lint: ANSI escape sequences
const ANSI = /\x1b\[[0-9;?]*[ -/]*[@-~]|\x1b\][^\x07]*\x07/g;

/** Every running group, so they go when the engine exits, even without a clean shutdown (they're detached). */
const live = new Set<number>();
let exitHook = false;
function watchExit(): void {
	if (exitHook) return;
	exitHook = true;
	process.on("exit", () => {
		for (const pid of live) {
			try {
				process.kill(-pid, "SIGKILL");
			} catch {
				/* already gone */
			}
		}
	});
}

type Entry = { info: BackgroundProcess; child: ChildProcess; buffer: string; dropped: number; read: number; ended: Promise<void> };

/** A session's background processes. */
export class ProcessManager {
	private readonly entries = new Map<string, Entry>();
	private next = 0;
	/** Called on every start, end or new address (the session state lists them). */
	onChange?: (processes: BackgroundProcess[]) => void;

	list(): BackgroundProcess[] {
		return [...this.entries.values()].map((e) => ({ ...e.info, urls: [...e.info.urls] }));
	}

	get(id: string): BackgroundProcess | undefined {
		const e = this.entries.get(id);
		return e ? { ...e.info, urls: [...e.info.urls] } : undefined;
	}

	/** Starts `commandLine` with `shell -c` in `cwd`; `command` is what the agent asked for (shown and listed). */
	start(command: string, commandLine: string, cwd: string, options: { shell: string; description?: string; env?: NodeJS.ProcessEnv } = { shell: "/bin/sh" }): BackgroundProcess {
		const running = [...this.entries.values()].filter((e) => e.info.status === "running").length;
		if (running >= MAX_RUNNING) throw new Error(`${MAX_RUNNING} background commands are already running. Stop one with process_stop first.`);
		const id = `p${++this.next}`;
		const child = spawn(options.shell, ["-c", commandLine], { cwd, env: { ...(options.env ?? process.env), FORCE_COLOR: "0", NO_COLOR: "1" }, detached: true, stdio: ["ignore", "pipe", "pipe"] });
		const info: BackgroundProcess = { id, command, ...(options.description ? { description: options.description } : {}), cwd, status: "running", startedAt: new Date().toISOString(), urls: [] };
		let resolveEnded!: () => void;
		const entry: Entry = { info, child, buffer: "", dropped: 0, read: 0, ended: new Promise((r) => (resolveEnded = r)) };
		this.entries.set(id, entry);
		if (child.pid) {
			live.add(child.pid);
			watchExit();
		}
		const take = (data: Buffer) => this.append(entry, data.toString("utf8"));
		child.stdout?.on("data", take);
		child.stderr?.on("data", take);
		child.on("error", (error) => this.append(entry, `\n${error.message}\n`));
		child.on("close", (code) => {
			if (child.pid) live.delete(child.pid);
			if (info.status === "running") info.status = "exited";
			info.exitCode = code;
			info.endedAt = new Date().toISOString();
			resolveEnded();
			this.changed();
		});
		this.changed();
		return { ...info };
	}

	private append(entry: Entry, text: string): void {
		const clean = text.replace(ANSI, "").replace(/\r(?!\n)/g, "\n");
		entry.buffer += clean;
		if (entry.buffer.length > KEEP_BYTES) {
			const cut = entry.buffer.length - KEEP_BYTES;
			entry.buffer = entry.buffer.slice(cut);
			entry.dropped += cut;
		}
		let found = false;
		for (const m of clean.matchAll(LOCAL_URL)) {
			const url = m[0].replace(/[.,;:]+$/, "").replace("0.0.0.0", "localhost");
			if (!entry.info.urls.includes(url)) {
				entry.info.urls.push(url);
				found = true;
			}
		}
		if (found) this.changed();
	}

	/**
	 * Output from `since` (a position from an earlier read; the agent's own last read when omitted), or the last `tail`
	 * lines. `next` is where the following read starts.
	 */
	output(id: string, options: { since?: number; tail?: number; markRead?: boolean } = {}): { text: string; next: number; skipped: number; process: BackgroundProcess } {
		const e = this.entries.get(id);
		if (!e) throw new Error(`There's no background command ${id}. process_list shows them.`);
		const end = e.dropped + e.buffer.length;
		let from = options.tail !== undefined ? end : (options.since ?? e.read);
		let text: string;
		if (options.tail !== undefined) {
			const lines = e.buffer.replace(/\n$/, "").split("\n");
			text = lines.slice(-Math.max(1, options.tail)).join("\n");
			from = end - text.length;
		} else text = e.buffer.slice(Math.max(0, from - e.dropped));
		const skipped = options.tail === undefined && from < e.dropped ? e.dropped - from : 0;
		if (options.markRead ?? options.since === undefined) e.read = end;
		return { text, next: end, skipped, process: { ...e.info, urls: [...e.info.urls] } };
	}

	/** Stops it and what it started: SIGTERM to its group, SIGKILL after `graceMs`. */
	async stop(id: string, graceMs = 3000): Promise<BackgroundProcess> {
		const e = this.entries.get(id);
		if (!e) throw new Error(`There's no background command ${id}. process_list shows them.`);
		if (e.info.status === "running") {
			e.info.status = "stopped";
			const kill = (signal: NodeJS.Signals) => {
				try {
					if (e.child.pid) process.kill(-e.child.pid, signal);
				} catch {
					e.child.kill(signal);
				}
			};
			kill("SIGTERM");
			const timer = setTimeout(() => kill("SIGKILL"), graceMs);
			await e.ended;
			clearTimeout(timer);
		}
		return { ...e.info, urls: [...e.info.urls] };
	}

	/** Waits until it prints a local address (a dev server is up), ends, or `ms` pass. */
	async settle(id: string, ms: number): Promise<void> {
		const e = this.entries.get(id);
		const until = Date.now() + ms;
		while (e && Date.now() < until && e.info.status === "running" && !e.info.urls.length) await new Promise((r) => setTimeout(r, 100));
	}

	async stopAll(): Promise<void> {
		await Promise.all([...this.entries.values()].filter((e) => e.info.status === "running").map((e) => this.stop(e.info.id, 1000)));
	}

	private changed(): void {
		this.onChange?.(this.list());
	}
}

/** How a background command's start reads to the agent. */
export function startedText(p: BackgroundProcess, output: string): string {
	const lines = [`Started in the background as ${p.id}: ${p.command}`];
	if (p.status !== "running") lines.push(`It already ended (exit ${p.exitCode ?? "?"}).`);
	if (p.urls.length) lines.push(`It's serving ${p.urls.join(", ")}`);
	lines.push(output.trim() ? `First output:\n${output.trimEnd()}` : "No output yet.");
	lines.push(`Read more with process_output {"id":"${p.id}"}; stop it with process_stop when you're done with it.`);
	return lines.join("\n");
}

function describeProcess(p: BackgroundProcess): string {
	const state = p.status === "running" ? "running" : p.status === "stopped" ? "stopped" : `ended (exit ${p.exitCode ?? "?"})`;
	return `${p.id} · ${state} · ${p.command}${p.urls.length ? ` · ${p.urls.join(", ")}` : ""}`;
}

/** process_output, process_stop and process_list, over the session's manager. */
export function backgroundExtension(processes: () => ProcessManager): ExtensionFactory {
	return (pi) => {
		pi.on("session_shutdown", () => {
			void processes().stopAll();
		});
		pi.registerTool({
			name: "process_output",
			label: "Read a background command",
			description: "What a command started with bash `background: true` printed since your last read (or its last lines with `tail`), and whether it's still running.",
			promptSnippet: "process_output: read what a background command printed",
			parameters: Type.Object({
				id: Type.String({ description: "Its id, like p1" }),
				tail: Type.Optional(Type.Number({ description: "Only its last N lines" })),
			}),
			async execute(_id: string, params: { id: string; tail?: number }) {
				try {
					const r = processes().output(params.id, params.tail !== undefined ? { tail: params.tail, markRead: true } : {});
					const head = describeProcess(r.process);
					const body = r.text.trim() ? `${r.skipped ? `(${r.skipped} earlier characters dropped)\n` : ""}${r.text.trimEnd()}` : "(nothing new)";
					return { content: [{ type: "text" as const, text: `${head}\n${body}` }], details: { process: r.process } };
				} catch (error) {
					return { content: [{ type: "text" as const, text: (error as Error).message }], details: {}, isError: true };
				}
			},
		} as never);
		pi.registerTool({
			name: "process_stop",
			label: "Stop a background command",
			description: "Stops a command started with bash `background: true`, and whatever it started.",
			promptSnippet: "process_stop: stop a background command",
			parameters: Type.Object({ id: Type.String({ description: "Its id, like p1" }) }),
			async execute(_id: string, params: { id: string }) {
				try {
					const p = await processes().stop(params.id);
					return { content: [{ type: "text" as const, text: `Stopped: ${describeProcess(p)}` }], details: { process: p } };
				} catch (error) {
					return { content: [{ type: "text" as const, text: (error as Error).message }], details: {}, isError: true };
				}
			},
		} as never);
		pi.registerTool({
			name: "process_list",
			label: "List background commands",
			description: "The commands started with bash `background: true` in this session: running, stopped or ended.",
			promptSnippet: "process_list: list background commands",
			parameters: Type.Object({}),
			async execute() {
				const list = processes().list();
				return { content: [{ type: "text" as const, text: list.length ? list.map(describeProcess).join("\n") : "No background commands." }], details: { processes: list } };
			},
		} as never);
	};
}
