/**
 * Engine-wide settings the app changes in Settings (07-shared §7): Chat's MCP servers and follow-up suggestions,
 * and the "About me" memory (07-shared §5). Kept in `<home>/settings.json`.
 */
import { existsSync, readFileSync } from "node:fs";
import type { EngineSettings } from "@piopio/protocol";
import { readJsonFile, writeFileAtomic } from "./atomic.js";

export const DEFAULT_SETTINGS: EngineSettings = {
	chat: { mcp: false, followUps: true },
	aboutMe: { enabled: false, capture: false, inThreads: true, provider: "builtin" },
	memory: { providers: [] },
};

export type SettingsPatch = { models?: NonNullable<EngineSettings["models"]>; build?: NonNullable<EngineSettings["build"]>; chat?: Partial<EngineSettings["chat"]>; aboutMe?: Partial<EngineSettings["aboutMe"]>; memory?: Partial<EngineSettings["memory"]> };

export class Settings {
	private value: EngineSettings;
	private listeners = new Set<(value: EngineSettings, previous: EngineSettings) => void>();

	constructor(private readonly file: string) {
		const saved = readJsonFile<SettingsPatch>(file, () => ({}));
		// Notebook settings from before docs/spec/18 phase 2, still in older files.
		delete (saved.chat as Record<string, unknown> | undefined)?.suggestSpaces;
		delete (saved.aboutMe as Record<string, unknown> | undefined)?.inSpaces;
		// Only `utility` (a `learning` choice existed for a day, 2026-11-06).
		const models = saved.models?.utility ? { utility: saved.models.utility } : undefined;
		this.value = { ...(models ? { models } : {}), ...(saved.build ? { build: saved.build } : {}), chat: { ...DEFAULT_SETTINGS.chat, ...saved.chat }, aboutMe: { ...DEFAULT_SETTINGS.aboutMe, ...saved.aboutMe }, memory: { ...DEFAULT_SETTINGS.memory, ...saved.memory } };
	}

	get(): EngineSettings {
		return structuredClone(this.value);
	}

	set(patch: SettingsPatch): EngineSettings {
		const previous = this.value;
		const models = { ...previous.models, ...patch.models };
		const build = { ...previous.build, ...patch.build };
		this.value = { ...(Object.keys(models).length ? { models } : {}), ...(Object.keys(build).length ? { build } : {}), chat: { ...previous.chat, ...patch.chat }, aboutMe: { ...previous.aboutMe, ...patch.aboutMe }, memory: { ...previous.memory, ...patch.memory } };
		writeFileAtomic(this.file, JSON.stringify(this.value, null, "\t"));
		for (const l of this.listeners) l(this.get(), previous);
		return this.get();
	}

	onChange(listener: (value: EngineSettings, previous: EngineSettings) => void): () => void {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	}
}
