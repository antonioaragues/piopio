/**
 * Agent Definition folders (docs/spec/06-agents §2): `agent.json` and `instructions.md` in a folder that is a git
 * repo, committed on every save, so the Definition tab has a history. Default home: `~/Piopio/Agents/<slug>`.
 */
import { existsSync, mkdirSync, readFileSync, renameSync, writeFileSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join } from "node:path";
import type { AgentDefinition } from "@piopio/runtime";
import { git } from "./git.js";

const AUTHOR = ["-c", "user.name=Piopio", "-c", "user.email=agents@piopio.local"];

export type AgentFolder = { definition: AgentDefinition; instructions: string };

export class AgentFiles {
	readonly root: string;

	constructor(root?: string) {
		this.root = root ?? process.env.PIOPIO_AGENTS_DIR ?? join(homedir(), "Piopio", "Agents");
	}

	/** A free folder for `slug` (coach, coach-2, …). */
	folderFor(slug: string): string {
		let dir = join(this.root, slug);
		for (let i = 2; existsSync(dir); i++) dir = join(this.root, `${slug}-${i}`);
		return dir;
	}

	async create(dir: string, folder: AgentFolder): Promise<void> {
		mkdirSync(join(dir, "skills"), { recursive: true });
		mkdirSync(join(dir, "knowledge"), { recursive: true });
		writeFileSync(join(dir, "skills", ".keep"), "");
		writeFileSync(join(dir, "knowledge", ".keep"), "");
		this.write(dir, folder);
		await git(dir, ["init", "-q", "-b", "main"]);
		await this.commit(dir, `Create ${folder.definition.name}`);
	}

	read(dir: string): AgentFolder {
		return {
			definition: JSON.parse(readFileSync(join(dir, "agent.json"), "utf8")) as AgentDefinition,
			instructions: existsSync(join(dir, "instructions.md")) ? readFileSync(join(dir, "instructions.md"), "utf8") : "",
		};
	}

	/** Writes and commits; returns false when nothing changed. */
	async save(dir: string, folder: AgentFolder, message: string): Promise<boolean> {
		this.write(dir, folder);
		return this.commit(dir, message);
	}

	async history(dir: string, limit = 30): Promise<{ commit: string; at: string; message: string }[]> {
		const out = await git(dir, ["log", `-${limit}`, "--format=%H%x1f%cI%x1f%s"]).catch(() => "");
		return out
			.split("\n")
			.filter(Boolean)
			.map((l) => {
				const [commit, at, message] = l.split("\x1f");
				return { commit: commit!, at: at!, message: message! };
			});
	}

	/** Moves the folder to the Trash (deleting an agent keeps its definition recoverable). */
	trash(dir: string, trashDir = join(homedir(), ".Trash")): void {
		if (!existsSync(dir)) return;
		mkdirSync(trashDir, { recursive: true });
		let target = join(trashDir, basename(dir));
		for (let i = 2; existsSync(target); i++) target = join(trashDir, `${basename(dir)} ${i}`);
		renameSync(dir, target);
	}

	private write(dir: string, folder: AgentFolder): void {
		writeFileSync(join(dir, "agent.json"), `${JSON.stringify(folder.definition, null, 2)}\n`);
		writeFileSync(join(dir, "instructions.md"), folder.instructions.endsWith("\n") ? folder.instructions : `${folder.instructions}\n`);
	}

	private async commit(dir: string, message: string): Promise<boolean> {
		await git(dir, ["add", "-A"]);
		if (!(await git(dir, ["status", "--porcelain"])).trim()) return false;
		await git(dir, [...AUTHOR, "commit", "-q", "-m", message]);
		return true;
	}
}
