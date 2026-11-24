/**
 * Ports that commands a coding agent started (Claude Code, Codex, Antigravity CLI) serve, for the project preview
 * (docs/spec/22 §6.1). Their background commands aren't Piopio's (05-build §9 TM4), so `process_list` can't name them;
 * what marks one as the session's is where it runs: a process under this engine (the agents' CLIs are its children)
 * whose working folder is the session's folder. A server you start in Terminal is never under the engine.
 */
import { execFile } from "node:child_process";
import { realpathSync } from "node:fs";

const run = (file: string, args: string[]) =>
	new Promise<string>((resolve) => execFile(file, args, { timeout: 3000, maxBuffer: 4 * 1024 * 1024 }, (_e, stdout) => resolve(stdout ?? "")));

const real = (path: string) => {
	try {
		return realpathSync(path);
	} catch {
		return path;
	}
};

/** The processes under `root` (not `root` itself), from `ps`. */
export async function descendants(root: number): Promise<number[]> {
	const children = new Map<number, number[]>();
	for (const line of (await run("ps", ["-A", "-o", "pid=,ppid="])).split("\n")) {
		const [pid, ppid] = line.trim().split(/\s+/).map(Number);
		if (!pid || ppid === undefined) continue;
		children.set(ppid, [...(children.get(ppid) ?? []), pid]);
	}
	const out: number[] = [];
	const queue = [...(children.get(root) ?? [])];
	while (queue.length) {
		const pid = queue.shift()!;
		out.push(pid);
		queue.push(...(children.get(pid) ?? []));
	}
	return out;
}

/** Ports listened on by processes under `root` (default: this engine) that run in `folder` or below it. */
export async function portsServedIn(folder: string, root = process.pid): Promise<number[]> {
	const pids = await descendants(root);
	if (!pids.length) return [];
	// `-F pn`: a "p<pid>" line, then its "n<address>" lines.
	const listening = new Map<number, Set<number>>();
	let pid = 0;
	for (const line of (await run("lsof", ["-a", "-nP", "-iTCP", "-sTCP:LISTEN", "-p", pids.join(","), "-F", "pn"])).split("\n")) {
		if (line.startsWith("p")) pid = Number(line.slice(1));
		const port = line.startsWith("n") ? Number(/:(\d+)$/.exec(line)?.[1]) : NaN;
		if (pid && port) listening.set(pid, (listening.get(pid) ?? new Set()).add(port));
	}
	if (!listening.size) return [];
	const base = real(folder);
	const ports = new Set<number>();
	// `-d cwd`: each process's working folder.
	pid = 0;
	for (const line of (await run("lsof", ["-a", "-p", [...listening.keys()].join(","), "-d", "cwd", "-F", "pn"])).split("\n")) {
		if (line.startsWith("p")) pid = Number(line.slice(1));
		if (!line.startsWith("n") || !pid) continue;
		const cwd = real(line.slice(1));
		if (cwd === base || cwd.startsWith(`${base}/`)) for (const p of listening.get(pid) ?? []) ports.add(p);
	}
	return [...ports].sort((a, b) => a - b);
}
