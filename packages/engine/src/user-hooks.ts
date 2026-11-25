/**
 * Your hooks (PAR6, docs/design/hooks): commands that run every time at a moment you pick, without the model deciding.
 * In pi a hook is an extension, so each one is a small, self-contained extension file Piopio writes from a sentence,
 * `hook-<name>.ts` in `~/.pi/agent/extensions/` (every project) or a project's `.pi/extensions/` (pi loads those only
 * once the project is trusted). The pi CLI runs the same files. The spec rides on the file's second line, so Piopio
 * reads it back; a file whose code was changed by hand is listed as code, never rewritten. Off is `.ts.off`.
 *
 * Moments, as pi's events: before a tool (`tool_call`, can stop it), after a tool (`tool_result`, a failure is told
 * to the model in the result), and when Piopio finishes an answer (`agent_before_settle`, a failing check sends its
 * output back and asks for one more turn, three times at most per message).
 */
import { existsSync, mkdirSync, readdirSync, readFileSync, renameSync } from "node:fs";
import { basename, join } from "node:path";
import { writeFileAtomic } from "./atomic.js";
import { EngineError } from "./models.js";

export type HookWhen = "before" | "after" | "end";
export type HookTool = "edit" | "write" | "bash" | "any";
export type HookSpec = {
	when: HookWhen;
	/** before/after: which tools ("edit" and "write" read files' paths; "bash" its command). */
	tools?: HookTool[];
	/** A glob on the file's path (edit/write); for "end", on the files the answer changed. No "/": the name only. */
	files?: string;
	/** bash: a glob on the command ("git push --force*"). */
	command?: string;
	/** The command to run: $FILE is the file, $COMMAND the command; the call comes as JSON on its input. */
	run?: string;
	/** before: stop the tool with this message (with `run`: only when the command exits 2, its output then). */
	stop?: string;
};

const MARK = "// piopio-hook ";

/**
 * Text that goes on one `//` line of the generated file. JavaScript ends a comment at \n, \r, U+2028 and U+2029: a
 * command holding one (a hook imported from a repository's .claude/settings.json) would put the rest of it on a line of
 * its own, as code that runs unsandboxed when pi loads the file (re-audit 2026-11-25 V3).
 */
const oneLine = (text: string) => text.replace(/[\r\n\u2028\u2029]+/g, " ");
/** JSON for a comment line or an expression: JSON.stringify leaves U+2028 and U+2029 unescaped. */
const lineJson = (value: unknown) => JSON.stringify(value).replace(/\u2028/g, "\\u2028").replace(/\u2029/g, "\\u2029");
const TOOL_WORDS: Record<HookTool, string> = { edit: "edits", write: "writes", bash: "runs a command", any: "uses any tool" };

/** The sentence a hook reads as (Settings and the file's first line). */
export function hookSentence(h: HookSpec): string {
	const tools = h.tools?.length ? h.tools : ["any" as const];
	const verbs = tools.includes("any") ? TOOL_WORDS.any : tools.filter((t) => t !== "bash").length === 2 ? `edits or writes${tools.includes("bash") ? " or runs a command" : ""}` : tools.map((t) => TOOL_WORDS[t]).join(" or ");
	const what = `${verbs}${h.files && !tools.includes("bash") ? ` a ${h.files} file` : ""}${h.command ? ` matching ${h.command}` : ""}`;
	if (h.when === "end") return `When Piopio finishes an answer${h.files ? ` that changed ${h.files} files` : ""}, run ${h.run}; if it fails, Piopio keeps going (3 times at most)`;
	if (h.when === "after") return `After Piopio ${what}, run ${h.run}`;
	if (h.run) return `Before Piopio ${what}, run ${h.run}; if it exits 2, stop it`;
	return `Before Piopio ${what}, stop it: "${h.stop ?? "Not allowed by your hook."}"`;
}

export function validHook(h: HookSpec): string | undefined {
	if (!["before", "after", "end"].includes(h.when)) return "Pick when it runs.";
	if (h.when !== "before" && !h.run?.trim()) return "Say what to run.";
	if (h.when === "before" && !h.run?.trim() && !h.stop?.trim()) return "Say what to run, or the message to stop with.";
	if (h.when !== "end" && !h.tools?.length) return "Pick which tools.";
	return undefined;
}

/** A name for its file, from what it runs or stops. */
export function hookName(h: HookSpec): string {
	// What it runs, else what it matches (a command, files), else what it says.
	const from = (h.run ?? h.command ?? h.files ?? h.stop ?? h.when).split(/\s+/).slice(0, 3).join(" ");
	const slug = from.toLowerCase().replace(/[^a-z0-9]+/g, "-").replace(/^-+|-+$/g, "").slice(0, 32) || "hook";
	return `hook-${slug}-${h.when === "end" ? "on-finish" : h.when}`;
}

/** The extension file for a hook: self-contained, so the pi CLI runs it without Piopio. */
export function hookSource(h: HookSpec): string {
	const spec = lineJson({ when: h.when, ...(h.tools ? { tools: h.tools } : {}), ...(h.files ? { files: h.files } : {}), ...(h.command ? { command: h.command } : {}), ...(h.run ? { run: h.run } : {}), ...(h.stop ? { stop: h.stop } : {}) });
	const label = h.run?.split(/\s+/)[0] ?? "your hook";
	const head = `// Piopio hook · ${oneLine(hookSentence(h))}
${MARK}${spec}
// Made in Piopio (Settings › Extensions › Your hooks). Change the code and Piopio lists it as code instead.
import { spawn } from "node:child_process";
import type { ExtensionAPI } from "@earendil-works/pi-coding-agent";

const HOOK = ${spec} as { when: string; tools?: string[]; files?: string; command?: string; run?: string; stop?: string };
const LABEL = ${lineJson(label)};

/** A glob as a pattern: * within a name, ** across folders; a pattern with no "/" matches the name alone. */
function glob(pattern: string, anything = false): RegExp {
\tconst body = pattern.replace(/[.+^\${}()|[\\]\\\\]/g, "\\\\$&").replace(/\\*\\*/g, "\\u0000").replace(/\\*/g, anything ? ".*" : "[^/]*").replace(/\\?/g, ".").replace(/\\u0000/g, ".*");
\treturn new RegExp(\`^\${body}$\`);
}
const fileMatches = (path: string) => !HOOK.files || glob(HOOK.files).test(HOOK.files.includes("/") ? path : path.split("/").pop() ?? path);
const toolMatches = (name: string) => !HOOK.tools?.length || HOOK.tools.includes("any") || HOOK.tools.includes(name);

/** Runs the command in the session's folder, at most 60 s; its output, and how it ended. */
function run(cwd: string, env: Record<string, string>, input: unknown): Promise<{ code: number; output: string }> {
\treturn new Promise((done) => {
\t\tconst child = spawn("/bin/sh", ["-c", HOOK.run ?? "true"], { cwd, env: { ...process.env, ...env } });
\t\tlet output = "";
\t\tconst take = (b: Buffer) => { if (output.length < 8000) output += b.toString(); };
\t\tchild.stdout.on("data", take);
\t\tchild.stderr.on("data", take);
\t\tconst timer = setTimeout(() => { child.kill("SIGKILL"); output += "\\n(stopped after 60 s)"; }, 60_000);
\t\tchild.on("close", (code) => { clearTimeout(timer); done({ code: code ?? 1, output: output.trim() }); });
\t\tchild.on("error", (e) => { clearTimeout(timer); done({ code: 1, output: String(e) }); });
\t\tchild.stdin.end(JSON.stringify(input));
\t});
}

function target(toolName: string, input: Record<string, unknown>): { ok: boolean; env: Record<string, string> } {
\tif (!toolMatches(toolName)) return { ok: false, env: {} };
\tif (toolName === "bash") {
\t\tconst command = String(input.command ?? "");
\t\treturn { ok: !HOOK.command || glob(HOOK.command, true).test(command.trim()), env: { COMMAND: command } };
\t}
\tconst file = String(input.path ?? input.file_path ?? "");
\treturn { ok: !file ? !HOOK.files : fileMatches(file), env: file ? { FILE: file } : {} };
}
`;
	if (h.when === "before")
		return `${head}
export default function (pi: ExtensionAPI) {
\tpi.on("tool_call", async (event, ctx) => {
\t\tconst { ok, env } = target(event.toolName, event.input as Record<string, unknown>);
\t\tif (!ok) return undefined;
\t\tif (!HOOK.run) return { block: true, reason: \`Stopped by your hook: \${HOOK.stop ?? "not allowed"}\` };
\t\tconst result = await run(ctx.cwd, env, { tool: event.toolName, input: event.input });
\t\treturn result.code === 2 ? { block: true, reason: \`Stopped by your hook \${LABEL}: \${result.output || HOOK.stop || "it exited 2"}\` } : undefined;
\t});
}
`;
	if (h.when === "after")
		return `${head}
export default function (pi: ExtensionAPI) {
\tpi.on("tool_result", async (event, ctx) => {
\t\tif (event.isError) return undefined;
\t\tconst { ok, env } = target(event.toolName, event.input as Record<string, unknown>);
\t\tif (!ok) return undefined;
\t\tconst result = await run(ctx.cwd, env, { tool: event.toolName, input: event.input });
\t\tif (result.code === 0) return undefined;
\t\treturn { content: [...event.content, { type: "text", text: \`Your hook \${LABEL} failed (exit \${result.code}):\\n\${result.output}\` }] };
\t});
}
`;
	return `${head}
export default function (pi: ExtensionAPI) {
\tlet changed = new Set<string>();
\tlet tries = 0;
\tpi.on("input", async () => { changed = new Set(); tries = 0; return undefined; });
\tpi.on("tool_result", async (event) => {
\t\tconst input = event.input as Record<string, unknown>;
\t\tif (!event.isError && (event.toolName === "edit" || event.toolName === "write")) changed.add(String(input.path ?? input.file_path ?? ""));
\t\treturn undefined;
\t});
\tpi.on("agent_before_settle", async (event, ctx) => {
\t\tif (HOOK.files && ![...changed].some(fileMatches)) return undefined;
\t\tif (!HOOK.files && changed.size === 0) return undefined;
\t\tif (tries >= 3) return undefined;
\t\tconst result = await run(ctx.cwd, {}, { changed: [...changed] });
\t\tif (result.code === 0) { changed = new Set(); return undefined; }
\t\ttries++;
\t\tconst text = \`Your hook \${LABEL} failed after this answer (try \${tries} of 3):\\n\${result.output}\\n\\nFix what it reports.\`;
\t\treturn { entries: [...event.entries, { type: "custom_message", customType: "piopio.hook", content: text, display: true }], continue: true };
\t});
}
`;
}

/** The spec of a file Piopio wrote, unchanged since; undefined for code (written or changed by hand). */
export function readHook(source: string): HookSpec | undefined {
	const line = source.split("\n").find((l) => l.startsWith(MARK));
	if (!line) return undefined;
	try {
		const spec = JSON.parse(line.slice(MARK.length)) as HookSpec;
		return hookSource(spec) === source ? spec : undefined;
	} catch {
		return undefined;
	}
}

export type HookFile = { path: string; name: string; on: boolean; spec?: HookSpec; sentence: string };

/** The hooks in an extensions folder: Piopio's (`hook-*.ts`, on or `.off`), as sentences; others aren't hooks. */
export function listHooks(dir: string): HookFile[] {
	if (!existsSync(dir)) return [];
	return readdirSync(dir)
		.filter((f) => /^hook-.+\.ts(\.off)?$/.test(f))
		.sort()
		.map((f) => {
			const path = join(dir, f);
			const spec = readHook(readFileSync(path, "utf8"));
			return { path, name: f.replace(/\.off$/, ""), on: !f.endsWith(".off"), ...(spec ? { spec } : {}), sentence: spec ? hookSentence(spec) : `${f.replace(/\.off$/, "")} (code)` };
		});
}

/** Writes a hook: a new file, or over the one it was (`previous`, which must still be Piopio's own). */
export function writeHook(dir: string, h: HookSpec, previous?: string): string {
	const problem = validHook(h);
	if (problem) throw new EngineError("INVALID", problem);
	if (previous && existsSync(previous) && !readHook(readFileSync(previous, "utf8"))) throw new EngineError("INVALID", "That file was changed by hand: edit it as code.");
	mkdirSync(dir, { recursive: true });
	const off = previous?.endsWith(".off") ?? false;
	let path = previous ?? join(dir, `${hookName(h)}.ts`);
	if (!previous) for (let i = 2; existsSync(path) || existsSync(`${path}.off`); i++) path = join(dir, `${hookName(h)}-${i}.ts`);
	writeFileAtomic(path, hookSource(h));
	return off ? path : path;
}

/** On or off: `.ts` loads, `.ts.off` doesn't. Returns the new path. */
export function toggleHook(path: string, on: boolean): string {
	const to = on ? path.replace(/\.off$/, "") : path.endsWith(".off") ? path : `${path}.off`;
	if (to !== path) renameSync(path, to);
	return to;
}

/**
 * Claude Code's hooks in a project's `.claude/settings.json`, as hooks: PreToolUse, PostToolUse and Stop with a
 * matcher on tool names and `command` hooks. Read only; what doesn't map (other events, prompts) is left out.
 */
export function claudeHooks(project: string): HookSpec[] {
	const file = join(project, ".claude", "settings.json");
	if (!existsSync(file)) return [];
	let hooks: Record<string, { matcher?: string; hooks?: { type?: string; command?: string }[] }[]> = {};
	try {
		hooks = (JSON.parse(readFileSync(file, "utf8")) as { hooks?: typeof hooks }).hooks ?? {};
	} catch {
		return [];
	}
	const tools = (matcher?: string): HookTool[] => {
		if (!matcher || matcher === "*" || matcher === ".*") return ["any"];
		const names = matcher.split("|").map((m) => m.trim().toLowerCase());
		const out = new Set<HookTool>();
		for (const n of names) {
			if (n === "edit" || n === "multiedit") out.add("edit");
			else if (n === "write") out.add("write");
			else if (n === "bash") out.add("bash");
		}
		return out.size ? [...out] : ["any"];
	};
	const out: HookSpec[] = [];
	const map: Record<string, HookWhen> = { PreToolUse: "before", PostToolUse: "after", Stop: "end" };
	for (const [event, groups] of Object.entries(hooks)) {
		const when = map[event];
		if (!when || !Array.isArray(groups)) continue;
		for (const g of groups) for (const h of g.hooks ?? []) if (h.type === "command" && h.command) out.push({ when, ...(when !== "end" ? { tools: tools(g.matcher) } : {}), run: h.command });
	}
	return out;
}

export const hookFileName = (path: string) => basename(path);

/** The same glob as the generated files: * within a name, ** across folders; no "/" matches the name alone. */
export function globMatch(pattern: string, path: string, anything = false): boolean {
	const body = pattern.replace(/[.+^${}()|[\]\\]/g, "\\$&").replace(/\*\*/g, "\u0000").replace(/\*/g, anything ? ".*" : "[^/]*").replace(/\?/g, ".").replace(/\u0000/g, ".*");
	return new RegExp(`^${body}$`).test(pattern.includes("/") || anything ? path : (path.split("/").pop() ?? path));
}

/** A file a hook would match, to try it on: the first one found under `root` (dependencies and build output skipped). */
export function sampleFile(root: string, pattern: string): string | undefined {
	const skip = new Set(["node_modules", ".git", "build", "dist", ".build", "DerivedData"]);
	const queue = [root];
	let seen = 0;
	while (queue.length && seen < 4000) {
		const dir = queue.shift()!;
		let entries: import("node:fs").Dirent[] = [];
		try {
			entries = readdirSync(dir, { withFileTypes: true });
		} catch {
			continue;
		}
		for (const e of entries) {
			seen++;
			const path = join(dir, e.name);
			if (e.isDirectory()) {
				if (!skip.has(e.name) && !e.name.startsWith(".")) queue.push(path);
			} else if (globMatch(pattern, path.slice(root.length + 1))) return path.slice(root.length + 1);
		}
	}
	return undefined;
}
