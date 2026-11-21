/**
 * Files kept per agent (docs/spec/06-agents §14): what the owner sent it (a policy, a photo of the tyres), kept in its
 * folder by the host, so it can find and read them months later. The host keeps them (the Mac's engine writes the
 * folder); this is what the agent gets: the tools, and the list for its system section.
 */
import { Type } from "typebox";
import { defineTool } from "@earendil-works/pi-durable";

export type AgentFileInfo = {
	name: string;
	/** What it is, in the agent's or the owner's words ("Póliza Mapfre 2026–27"). */
	note?: string;
	kind: "image" | "pdf" | "text" | "other";
	size: number;
	/** When it was kept (ISO). */
	addedAt: string;
	/** Where it is on disk, for the app's cards. */
	path: string;
	/** Whether read_file has something to give the model (a PDF dropped in Finder has no text yet). */
	readable: boolean;
};

export type AgentFileRead = { text: string; total: number } | { image: { data: string; mimeType: string } } | { error: string };

/** What the host does with an agent's files. */
export type AgentFilesBridge = {
	list(): Promise<AgentFileInfo[]>;
	read(name: string, from?: number): Promise<AgentFileRead>;
	note(name: string, change: { note?: string; rename?: string }): Promise<AgentFileInfo>;
	/** Moves it aside; the token puts it back (Undo). */
	remove(name: string): Promise<{ token: string; file: AgentFileInfo }>;
	restore(token: string): Promise<void>;
};

/** A file's text, this much at a time. */
export const READ_CHARS = 30_000;
/** About 1,000 tokens of the file list in the system section; past that, list_files. */
const LIST_IN_PROMPT = 4000;

const size = (n: number) => (n < 1024 ? `${n} B` : n < 1024 * 1024 ? `${Math.round(n / 1024)} KB` : `${(n / 1024 / 1024).toFixed(1)} MB`);

/** One line per file, newest first: name · note · kind, size · date. */
export function fileLines(files: readonly AgentFileInfo[]): string {
	return files.map((f) => `- ${f.name}${f.note ? ` · ${f.note}` : ""} (${f.kind}, ${size(f.size)}, ${f.addedAt.slice(0, 10)}${f.readable ? "" : ", no text to read yet"})`).join("\n");
}

/** The system section: the files it has, and how to use them. Undefined when there are none. */
export function filesSection(files: readonly AgentFileInfo[]): string | undefined {
	if (!files.length) return undefined;
	const all = fileLines(files);
	const shown = all.length > LIST_IN_PROMPT ? `${all.slice(0, all.lastIndexOf("\n", LIST_IN_PROMPT))}\n- … more: list_files` : all;
	return `Your files (kept in your folder; every file your owner sends you is kept here on its own):\n${shown}\n\nWhen something you need may be in one (a date, a number, what a policy covers), read_file it rather than guessing. When a new file has no note or its name says little, note_file it with what it is. When your owner asks for one, hand it over with present_files.`;
}

export type FileToolsHost = {
	bridge: () => AgentFilesBridge | undefined;
	/** Only the owner's conversation and runs: the files are the owner's. */
	allowed: (conversationId: unknown) => Promise<boolean>;
	recordUndo: (token: string, title: string, conversationId: unknown) => Promise<string | undefined>;
};

const NOT_HERE = "Your files are your owner's: they're only open in your owner's conversation and your runs.";

export function fileTools(host: FileToolsHost) {
	const text = (t: string, isError = false) => ({ output: [{ type: "text" as const, text: t }], ...(isError ? { isError: true } : {}) });
	const ready = async (conversationId: unknown) => {
		const bridge = host.bridge();
		if (!bridge) return { error: text("Files aren't kept where you run now.", true) };
		if (!(await host.allowed(conversationId))) return { error: text(NOT_HERE, true) };
		return { bridge };
	};

	const listFiles = defineTool({
		name: "list_files",
		description: "List every file you keep (name, note, kind, size, date).",
		parameters: Type.Object({}),
		execute: async (_args, api) => {
			const r = await ready(api.conversationId);
			if (!r.bridge) return r.error;
			const files = await r.bridge.list();
			return text(files.length ? fileLines(files) : "No files yet. Every file your owner sends you is kept.");
		},
	});

	const readFile = defineTool({
		name: "read_file",
		description: `Read one of your files: a text's or a PDF's text (${READ_CHARS.toLocaleString("en")} characters at a time; pass from to go on), or look at an image.`,
		parameters: Type.Object({
			name: Type.String({ description: "The file's name, as your files list it" }),
			from: Type.Optional(Type.Integer({ minimum: 0, description: "Where to start, in characters (for long texts)" })),
		}),
		execute: async (args, api) => {
			const r = await ready(api.conversationId);
			if (!r.bridge) return r.error;
			const got = await r.bridge.read(args.name, args.from);
			if ("error" in got) return text(got.error, true);
			if ("image" in got) return { output: [{ type: "text" as const, text: `${args.name}:` }, { type: "image" as const, data: got.image.data, mimeType: got.image.mimeType }] };
			const from = args.from ?? 0;
			const end = from + got.text.length;
			const more = end < got.total ? `\n\n[… ${got.total - end} more characters: read_file with from=${end}]` : "";
			return text(`${args.name}${from ? ` (from character ${from} of ${got.total})` : ""}:\n${got.text}${more}`);
		},
	});

	const noteFile = defineTool({
		name: "note_file",
		description: "Say what one of your files is (it shows next to it in your list and in the owner's Files), or give it a clearer name.",
		parameters: Type.Object({
			name: Type.String(),
			note: Type.Optional(Type.String({ maxLength: 200, description: "What it is, in a few words" })),
			rename: Type.Optional(Type.String({ minLength: 1, maxLength: 120, description: "A new name; its extension is kept" })),
		}),
		execute: async (args, api) => {
			const r = await ready(api.conversationId);
			if (!r.bridge) return r.error;
			if (args.note === undefined && !args.rename) return text("Give a note or a new name.", true);
			try {
				const f = await r.bridge.note(args.name, { ...(args.note !== undefined ? { note: args.note } : {}), ...(args.rename ? { rename: args.rename } : {}) });
				return text(`Noted: ${f.name}${f.note ? ` · ${f.note}` : ""}.`);
			} catch (error) {
				return text((error as Error).message, true);
			}
		},
	});

	const presentFiles = defineTool({
		name: "present_files",
		description: "Hand your owner one or more of your files: they show as cards they can open, reveal in Finder or drag out.",
		parameters: Type.Object({ names: Type.Array(Type.String(), { minItems: 1, maxItems: 10 }) }),
		execute: async (args, api) => {
			const r = await ready(api.conversationId);
			if (!r.bridge) return r.error;
			const files = await r.bridge.list();
			const found = args.names.map((n) => files.find((f) => f.name === n) ?? files.find((f) => f.name.toLowerCase() === n.toLowerCase()));
			const missing = args.names.filter((_, i) => !found[i]);
			const cards = found.filter((f): f is AgentFileInfo => f !== undefined).map((f) => ({ path: f.path, name: f.name, ...(f.note ? { description: f.note } : {}), size: f.size }));
			if (!cards.length) return text(`No file named ${missing.join(", ")}. Your files: ${files.map((f) => f.name).join(", ") || "none"}.`, true);
			return {
				output: [{ type: "text" as const, text: `Shown: ${cards.map((c) => c.name).join(", ")}.${missing.length ? ` Not found: ${missing.join(", ")}.` : ""}` }],
				details: { files: cards } as never,
			};
		},
	});

	const deleteFile = defineTool({
		name: "delete_file",
		description: "Delete one of your files, when your owner asks or it's plainly no longer wanted (a duplicate). They see a card with Undo.",
		parameters: Type.Object({ name: Type.String() }),
		execute: async (args, api) => {
			const r = await ready(api.conversationId);
			if (!r.bridge) return r.error;
			try {
				const { token, file } = await r.bridge.remove(args.name);
				const undo = await host.recordUndo(token, `deleting ${file.name}`, api.conversationId);
				return { output: [{ type: "text" as const, text: `Deleted ${file.name}.` }], details: { card: { kind: "file", title: "Deleted a file", detail: file.name }, ...(undo ? { undo } : {}) } as never };
			} catch (error) {
				return text((error as Error).message, true);
			}
		},
	});

	return { listFiles, readFile, noteFile, presentFiles, deleteFile, all: [listFiles, readFile, noteFile, presentFiles, deleteFile] };
}
