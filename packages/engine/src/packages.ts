/**
 * pi packages (docs/spec/07-shared-resources §6.1): the user's packages in `~/.pi/agent/settings.json`, shared with
 * the pi CLI, managed with pi's own package manager (the code behind `pi install`). Turning a package off writes
 * pi's filter form (`{ source, extensions: [], skills: [], prompts: [], themes: [] }`), so the CLI agrees.
 */
import { homedir } from "node:os";
import { DefaultPackageManager, SettingsManager, type PackageSource } from "@earendil-works/pi-coding-agent";
import type { PiPackage } from "@piopio/protocol";
import { EngineError } from "./models.js";

const KINDS = ["extensions", "skills", "prompts", "themes"] as const;
type Kind = (typeof KINDS)[number];

export class Packages {
	private listeners = new Set<() => void>();
	private busy: Promise<unknown> = Promise.resolve();

	constructor(private readonly agentDir: string) {}

	private manager() {
		const settings = SettingsManager.create(homedir(), this.agentDir);
		return { settings, packages: new DefaultPackageManager({ cwd: homedir(), agentDir: this.agentDir, settingsManager: settings }) };
	}

	async list(): Promise<PiPackage[]> {
		const { settings, packages } = this.manager();
		const resolved = await packages.resolve(async () => "skip").catch(() => ({ extensions: [], skills: [], prompts: [], themes: [] }));
		const entries = settings.getPackages();
		return packages
			.listConfiguredPackages()
			.filter((p) => p.scope === "user")
			.map((p) => {
				const entry = entries.find((e) => sourceOf(e) === p.source);
				const filters = typeof entry === "object" ? (entry as Record<string, unknown>) : {};
				const off = KINDS.filter((k) => Array.isArray(filters[k]) && (filters[k] as unknown[]).length === 0);
				const resources = Object.fromEntries(
					KINDS.map((k) => [k, resolved[k].filter((r) => r.metadata.origin === "package" && r.metadata.source === p.source).map((r) => ({ path: r.path, enabled: r.enabled }))]),
				) as PiPackage["resources"];
				return {
					source: p.source,
					...(p.installedPath ? { installedPath: p.installedPath } : {}),
					installed: Boolean(p.installedPath),
					enabled: off.length < KINDS.length,
					off,
					resources,
				};
			});
	}

	/** Installs from `npm:…`, `git:…`, a URL or a local path, and adds it to the settings. */
	install(source: string): Promise<void> {
		return this.run(async () => {
			const clean = source.trim();
			if (!clean) throw new EngineError("INVALID", "Give a package: npm:name, git:host/repo, a URL or a folder.");
			await this.manager().packages.installAndPersist(clean);
		});
	}

	remove(source: string): Promise<void> {
		return this.run(async () => {
			if (!(await this.manager().packages.removeAndPersist(source))) throw new EngineError("NOT_FOUND", `No package ${source}`);
		});
	}

	update(source?: string): Promise<void> {
		return this.run(() => this.manager().packages.update(source));
	}

	/** On or off, for the whole package or some kinds of resources (`kinds` omitted: all of them). */
	setEnabled(source: string, enabled: boolean, kinds: readonly Kind[] = KINDS): Promise<void> {
		return this.run(async () => {
			const { settings } = this.manager();
			const entries = settings.getPackages();
			const i = entries.findIndex((e) => sourceOf(e) === source);
			if (i < 0) throw new EngineError("NOT_FOUND", `No package ${source}`);
			const entry: Record<string, unknown> = typeof entries[i] === "object" ? { ...(entries[i] as object) } : { source };
			for (const k of kinds) {
				if (enabled) delete entry[k];
				else entry[k] = [];
			}
			const next = [...entries];
			next[i] = (Object.keys(entry).length === 1 ? source : entry) as PackageSource;
			settings.setPackages(next);
			await settings.flush();
		});
	}

	onChange(listener: () => void): () => void {
		this.listeners.add(listener);
		return () => this.listeners.delete(listener);
	}

	/** One change at a time (npm and git don't like concurrent installs); listeners hear about each. */
	private run(work: () => Promise<void>): Promise<void> {
		const next = this.busy.then(work, work);
		this.busy = next.catch(() => undefined);
		return next.then(() => {
			for (const l of this.listeners) l();
		});
	}
}

function sourceOf(entry: PackageSource): string {
	return typeof entry === "string" ? entry : (entry as { source: string }).source;
}
