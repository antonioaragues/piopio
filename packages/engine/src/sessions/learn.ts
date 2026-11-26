/**
 * /learn cards (docs/spec/14 M5): what a conversation's /learn tool may write (`bridge`), saving a card (rules into the
 * project's instructions file, facts into About me, skills into your skills folder), and Not now, Dismiss or Undo,
 * which takes out exactly what a save wrote. A card's state is its catalog entry's (`learned`, `learnUndo`); everything
 * this needs from the conversations comes through `LearnHost`, which Sessions implements.
 */
import { readFileSync, rmSync } from "node:fs";
import { homedir } from "node:os";
import { dirname, join, resolve } from "node:path";
import type { ContainerRef, LearnItem } from "@piopio/protocol";
import type { AboutMe } from "../about-me.js";
import { writeFileAtomic } from "../atomic.js";
import type { ChatResources } from "../tools/chat-resources.js";
import { addRules, instructionsFile, readInstructions, removeRules } from "../learn.js";
import { EngineError } from "../models.js";
import type { Runtime } from "../runtimes/runtime.js";
import { formatSkill, parseSkill, skillName, skillsRoot, writeSkill } from "../skills.js";
import type { LearnBridge } from "../tools/learn.js";
import type { CatalogEntry } from "./catalog-entry.js";

export interface LearnHost {
	entry(ref: ContainerRef): CatalogEntry;
	runtime(ref: ContainerRef): Promise<Runtime>;
	/** About me and your skills, where chats have them. */
	chat(): { aboutMe: AboutMe; resources: ChatResources } | undefined;
	/** The entry changed: write the catalog, and tell clients (`changed`). */
	save(): void;
	changed(entry: CatalogEntry): void;
	/** Skills changed: open conversations read them again. */
	reloadResources(): Promise<void>;
}

export class LearnCards {
	constructor(private readonly host: LearnHost) {}

	/**
	 * /learn (docs/spec/14 M5): rules go into the project's instructions file where the session works (a worktree's own
	 * copy, so they travel with its branch); facts go to About me. Not for agents, helpers or subagents.
	 */
	bridge(entry: CatalogEntry): LearnBridge | undefined {
		if ((entry.ref.kind !== "build" && entry.ref.kind !== "thread") || entry.parent || entry.helper || entry.reviewFor) return undefined;
		const project = entry.ref.kind === "build" ? entry.cwd : undefined;
		return {
			project: () => project,
			file: () => (project ? instructionsFile(project) : undefined),
			aboutMe: () => !entry.temporary && Boolean(this.host.chat()),
			proposed: (callId) => {
				(entry.learned ??= {})[callId] = { status: "pending" };
				this.host.save();
				this.host.changed(entry);
			},
			skills: async () => (await this.yourSkills()).map((s) => s.name),
		};
	}

	/** Your skills (every project's folder): the ones /learn may add to. */
	private async yourSkills(): Promise<{ name: string; filePath: string }[]> {
		const resources = this.host.chat()?.resources;
		if (!resources) return [];
		const roots = [skillsRoot(resources.agentDir), join(homedir(), ".agents", "skills")].map((r) => `${resolve(r)}/`);
		return (await resources.allSkills()).filter((s) => roots.some((r) => resolve(s.filePath).startsWith(r)) && s.filePath.endsWith("SKILL.md"));
	}

	/** Saves a /learn card: its items, or the ones you edited. */
	async save(ref: ContainerRef, callId: string, edited?: LearnItem[]): Promise<{ file?: string; project: number; aboutMe: number; skills: string[] }> {
		const entry = this.host.entry(ref);
		const chat = this.host.chat();
		const state = entry.learned?.[callId];
		if (!state) throw new EngineError("NOT_FOUND", "That card isn't in this conversation.");
		if (state.status === "saved") throw new EngineError("INVALID", "It's saved already.");
		const tool = (await this.host.runtime(ref)).snapshot().items.find((i) => i.kind === "tool" && i.callId === callId);
		const details = tool?.kind === "tool" && tool.details?.type === "learn" ? tool.details : undefined;
		const items = edited ?? details?.items ?? [];
		const project = entry.ref.kind === "build" ? entry.cwd : undefined;
		const rules = project ? items.filter((i) => i.to === "project" && i.text.trim()) : [];
		const facts = items.filter((i) => i.to === "about_me" && i.text.trim()).map((i) => i.text.trim());
		const undo: NonNullable<CatalogEntry["learnUndo"]>[string] = { lines: [], facts: [] };
		if (rules.length && project) {
			const file = details?.file ?? instructionsFile(project);
			const before = readInstructions(project, file);
			const { content, added } = addRules(before, rules);
			if (added.length) {
				writeFileAtomic(join(project, file), content);
				Object.assign(undo, { project, file, lines: added, ...(before ? {} : { created: true }) });
			}
		}
		if (facts.length && chat && !entry.temporary) undo.facts = (await chat.aboutMe.patch("user", facts, [])).added;
		// Skills (docs/spec/40 SH0): a new folder, or more instructions in one of yours.
		const skills = items.filter((i) => i.to === "skill" && i.name?.trim() && i.body?.trim());
		const named: string[] = [];
		if (skills.length && chat?.resources) {
			const agentDir = chat.resources.agentDir;
			const mine = await this.yourSkills();
			for (const item of skills) {
				const target = item.addTo ? mine.find((s) => s.name === item.addTo) : undefined;
				if (target) {
					const text = readFileSync(target.filePath, "utf8");
					const parsed = parseSkill(text);
					writeFileAtomic(target.filePath, formatSkill({ ...parsed, body: `${parsed.body}\n\n${item.body!.trim()}` }, parsed.other));
					(undo.skillsBefore ??= []).push({ path: target.filePath, text });
					named.push(target.name);
				} else {
					const path = writeSkill(skillsRoot(agentDir, item.projectOnly && project ? project : undefined), { name: item.name!, description: item.text, body: item.body! });
					(undo.skillsMade ??= []).push(dirname(path));
					named.push(skillName(item.name!));
				}
			}
			await chat.resources.reload();
			await this.host.reloadResources();
		}
		(entry.learnUndo ??= {})[callId] = undo;
		entry.learned![callId] = { status: "saved", ...(undo.file ? { file: undo.file } : {}), ...(undo.facts.length ? { aboutMe: undo.facts.length } : {}), ...(named.length ? { skills: named } : {}) };
		this.host.save();
		this.host.changed(entry);
		return { ...(undo.file ? { file: undo.file } : {}), project: undo.lines.length, aboutMe: undo.facts.length, skills: named };
	}

	/** Not now, Dismiss, or Undo a save: exactly what it wrote comes out, and the card waits again. */
	async answer(ref: ContainerRef, callId: string, choice: "later" | "dismiss" | "undo"): Promise<void> {
		const entry = this.host.entry(ref);
		const chat = this.host.chat();
		const state = entry.learned?.[callId];
		if (!state) throw new EngineError("NOT_FOUND", "That card isn't in this conversation.");
		if (choice !== "undo") {
			if (state.status === "saved") throw new EngineError("INVALID", "It's saved: use Undo.");
			entry.learned![callId] = { status: choice === "later" ? "later" : "dismissed" };
		} else {
			const undo = entry.learnUndo?.[callId];
			if (state.status !== "saved" || !undo) throw new EngineError("INVALID", "There's nothing saved to undo.");
			if (undo.project && undo.file && undo.lines.length) {
				const path = join(undo.project, undo.file);
				const left = removeRules(readInstructions(undo.project, undo.file), undo.lines);
				if (!left && undo.created) rmSync(path, { force: true });
				else writeFileAtomic(path, left);
			}
			if (undo.facts.length && chat) await chat.aboutMe.patch("user", [], undo.facts);
			for (const folder of undo.skillsMade ?? []) rmSync(folder, { recursive: true, force: true });
			for (const before of undo.skillsBefore ?? []) writeFileAtomic(before.path, before.text);
			if ((undo.skillsMade?.length || undo.skillsBefore?.length) && chat?.resources) {
				await chat.resources.reload();
				await this.host.reloadResources();
			}
			delete entry.learnUndo![callId];
			entry.learned![callId] = { status: "pending" };
		}
		this.host.save();
		this.host.changed(entry);
	}
}
