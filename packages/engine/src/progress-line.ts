import { basename } from "node:path";

/**
 * What a subagent is doing, in plain words, for its row and its task card (docs/spec/37 SB3): "Reading oauth.ts",
 * "Searching for Keychain", a command's own description. Never the raw command.
 */
export function progressLine(tool: string, args: unknown): string {
	const a = (args ?? {}) as Record<string, unknown>;
	const str = (k: string) => (typeof a[k] === "string" ? (a[k] as string).trim() : "");
	const file = (p: string) => basename(p.replace(/\/+$/, "")) || p;
	const short = (s: string, n = 60) => (s.length > n ? `${s.slice(0, n - 1).trimEnd()}…` : s);
	switch (tool) {
		case "read":
			return str("path") ? `Reading ${file(str("path"))}` : "Reading a file";
		case "edit":
			return str("path") ? `Editing ${file(str("path"))}` : "Editing a file";
		case "write":
			return str("path") ? `Writing ${file(str("path"))}` : "Writing a file";
		case "grep":
			return str("pattern") ? `Searching for ${short(str("pattern"), 40)}` : "Searching";
		case "find":
		case "ls":
			return str("path") && str("path") !== "." ? `Looking through ${file(str("path"))}` : "Looking through the files";
		case "bash":
			return str("description") ? short(str("description"), 80) : commandLine(str("command"));
		case "web_search":
			return str("query") ? `Searching the web for ${short(str("query"), 50)}` : "Searching the web";
		case "web_fetch": {
			const url = str("url");
			try {
				return `Reading ${new URL(url).host.replace(/^www\./, "")}`;
			} catch {
				return "Reading a page";
			}
		}
		case "todo":
			return "Updating its checklist";
		case "task":
			return str("description") ? `Starting ${short(str("description"), 50)}` : "Starting a subagent";
		default: {
			if (tool.startsWith("mcp__")) return `Using ${tool.split("__")[1]?.replace(/[-_]/g, " ") ?? "a connected app"}`;
			const words = tool.replace(/[-_]/g, " ").trim();
			return words ? words[0]!.toUpperCase() + words.slice(1) : "Working";
		}
	}
}

/** A command without a description, read from its first real step: `cd x && sed -n … file` is "Reading file". */
function commandLine(command: string): string {
	// Split on && || ; and newlines outside quotes (a sed script's ";" stays in its step).
	const parts: string[] = [];
	let cur = "", quote = "";
	for (let i = 0; i < command.length; i++) {
		const c = command[i]!;
		if (quote) { if (c === quote) quote = ""; cur += c; continue; }
		if (c === "'" || c === '"') { quote = c; cur += c; continue; }
		const two = command.slice(i, i + 2);
		if (two === "&&" || two === "||") { parts.push(cur); cur = ""; i++; continue; }
		if (c === ";" || c === "\n") { parts.push(cur); cur = ""; continue; }
		cur += c;
	}
	parts.push(cur);
	const steps = parts.map((s) => s.trim()).filter((s) => s && !/^(cd|export|set|source|\.)\s/.test(s) && s !== "cd");
	const step = steps[0];
	if (!step) return "Running a command";
	const words = step.split(/\s+/);
	const run = (words[0] ?? "").replace(/^.*\//, "");
	const rest = words.slice(1).join(" ");
	const lastFile = () => {
		const f = [...words.slice(1)].reverse().find((w) => !w.startsWith("-") && !/^['"]?\d/.test(w) && /[\w.]/.test(w));
		return f ? basename(f.replace(/^['"]|['"]$/g, "")) : "";
	};
	if (/\btest\b|vitest|jest|pytest|xctest/.test(step) || (run === "swift" && words[1] === "test")) return "Running the tests";
	if (/^(cat|sed|head|tail|less|bat|nl|wc)$/.test(run)) return lastFile() ? `Reading ${lastFile()}` : "Reading a file";
	if (/^(rg|grep|ag|ack)$/.test(run)) {
		const pattern = words.slice(1).find((w) => !w.startsWith("-"));
		return pattern ? `Searching for ${pattern.replace(/^['"]|['"]$/g, "").slice(0, 40)}` : "Searching";
	}
	if (/^(ls|find|tree|fd)$/.test(run)) return "Looking through the files";
	if (run === "git") return `Checking git${words[1] ? ` (${words[1]})` : ""}`;
	if (/^(xcodebuild|tsc|make|cargo|go)$/.test(run) || (run === "swift" && words[1] === "build") || /\b(build|typecheck)\b/.test(rest)) return "Building";
	if (/^(npm|pnpm|yarn|bun|npx)$/.test(run) && /\b(install|add|i)\b/.test(rest)) return "Installing packages";
	if (/^(curl|wget)$/.test(run)) return "Fetching a page";
	return `Running ${run}`;
}
