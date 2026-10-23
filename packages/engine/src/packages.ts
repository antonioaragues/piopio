/**
 * pi packages (docs/spec/07-shared-resources §6.1): the user's packages in `~/.pi/agent/settings.json`, shared with
 * the pi CLI, managed with pi's own package manager (the code behind `pi install`). Turning a package off writes
 * pi's filter form (`{ source, extensions: [], skills: [], prompts: [], themes: [] }`), so the CLI agrees.
 */
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, isAbsolute, join, relative, resolve } from "node:path";
import { DefaultPackageManager, SettingsManager, type PackageSource } from "@earendil-works/pi-coding-agent";
import type { PackagePreview, PiPackage } from "@piopio/protocol";
import { EngineError } from "./models.js";

const KINDS = ["extensions", "skills", "prompts", "themes"] as const;
type Kind = (typeof KINDS)[number];

const LATEST_TTL_MS = 60 * 60_000;

export class Packages {
	private listeners = new Set<() => void>();
	private busy: Promise<unknown> = Promise.resolve();
	private readonly latest = new Map<string, { at: number; version: Promise<string | undefined> }>();

	constructor(
		private readonly agentDir: string,
		private readonly fetchImpl: typeof fetch = fetch,
	) {}

	private manager() {
		const settings = SettingsManager.create(homedir(), this.agentDir);
		return { settings, packages: new DefaultPackageManager({ cwd: homedir(), agentDir: this.agentDir, settingsManager: settings }) };
	}

	async list(): Promise<PiPackage[]> {
		const { settings, packages } = this.manager();
		const resolved = await packages.resolve(async () => "skip").catch(() => ({ extensions: [], skills: [], prompts: [], themes: [] }));
		const entries = settings.getPackages();
		const listed = packages
			.listConfiguredPackages()
			.filter((p) => p.scope === "user")
			.map((p) => {
				const entry = entries.find((e) => sourceOf(e) === p.source);
				const filters = typeof entry === "object" ? (entry as Record<string, unknown>) : {};
				const off = KINDS.filter((k) => Array.isArray(filters[k]) && (filters[k] as unknown[]).length === 0);
				const resources = Object.fromEntries(
					KINDS.map((k) => [k, resolved[k].filter((r) => r.metadata.origin === "package" && r.metadata.source === p.source).map((r) => ({ path: r.path, enabled: r.enabled }))]),
				) as PiPackage["resources"];
				const meta = p.installedPath ? readMeta(p.installedPath) : {};
				return {
					source: p.source,
					kind: kindOf(p.source),
					...(p.installedPath ? { installedPath: p.installedPath } : {}),
					installed: Boolean(p.installedPath),
					enabled: off.length < KINDS.length,
					off,
					resources,
					...(meta.name ? { name: meta.name } : {}),
					...(meta.version ? { version: meta.version } : {}),
					...(meta.description ? { description: meta.description } : {}),
				} satisfies PiPackage;
			});
		// Updates: unpinned npm packages whose registry version is newer (checked at most hourly, never blocking long).
		return Promise.all(
			listed.map(async (p) => {
				const spec = p.kind === "npm" ? npmSpec(p.source) : undefined;
				if (!spec || spec.pinned || !p.version) return p;
				const latest = await this.latestVersion(spec.name);
				return latest && newer(latest, p.version) ? { ...p, latest } : p;
			}),
		);
	}

	private latestVersion(name: string): Promise<string | undefined> {
		const hit = this.latest.get(name);
		if (hit && Date.now() - hit.at < LATEST_TTL_MS) return hit.version;
		const version = this.fetchJson(`https://registry.npmjs.org/${encodeName(name)}/latest`, 4_000).then((j) => (typeof j?.version === "string" ? j.version : undefined));
		this.latest.set(name, { at: Date.now(), version });
		return version;
	}

	private async fetchJson(url: string, timeoutMs = 8_000): Promise<Record<string, unknown> | undefined> {
		try {
			const response = await this.fetchImpl(url, { signal: AbortSignal.timeout(timeoutMs), headers: { accept: "application/json" } });
			return response.ok ? ((await response.json()) as Record<string, unknown>) : undefined;
		} catch {
			return undefined;
		}
	}

	/**
	 * What a package would add, before installing (Settings › Extensions, Install sheet): its name, version and
	 * description, and its extensions, skills, templates and themes. npm packages are read from the registry (contents
	 * from its manifest or the file list); GitHub repositories from their package.json and folders; folders from disk.
	 */
	async preview(source: string): Promise<PackagePreview> {
		const clean = source.trim();
		const kind = kindOf(clean);
		const empty = { extensions: [], skills: [], prompts: [], themes: [] };
		if (!clean) return { ok: false, kind, ...empty, contentsKnown: false, error: "Type a package." };
		if (kind === "local") {
			const dir = resolve(clean.replace(/^~(?=\/|$)/, homedir()));
			if (!existsSync(dir)) return { ok: false, kind, ...empty, contentsKnown: false, error: "There's no folder there." };
			const meta = statSync(dir).isDirectory() ? readMeta(dir) : {};
			const files = statSync(dir).isDirectory() ? walk(dir) : [basename(dir)];
			return { ok: true, kind, ...metaFields(meta), ...contents(meta.pi, files), contentsKnown: true };
		}
		if (kind === "npm") {
			const spec = npmSpec(clean);
			if (!spec) return { ok: false, kind, ...empty, contentsKnown: false, error: "That doesn't look like an npm package name." };
			const meta = (await this.fetchJson(`https://registry.npmjs.org/${encodeName(spec.name)}/${spec.version ?? "latest"}`)) as Meta | undefined;
			if (!meta?.version) return { ok: false, kind, ...empty, contentsKnown: false, error: `No package ${spec.name} on npm.` };
			const tree = await this.fetchJson(`https://data.jsdelivr.com/v1/packages/npm/${spec.name}@${meta.version}?structure=flat`);
			const files = Array.isArray(tree?.files) ? (tree.files as { name: string }[]).map((f) => f.name.replace(/^\//, "")) : undefined;
			return { ok: true, kind, ...metaFields(meta), ...contents(meta.pi, files ?? []), contentsKnown: Boolean(meta.pi || files) };
		}
		const repo = /github\.com[/:]([^/]+)\/([^/@#]+?)(?:\.git)?(?:[@#](.+))?$/.exec(clean);
		if (!repo) return { ok: true, kind, ...empty, contentsKnown: false };
		const [, owner, name, ref = "HEAD"] = repo;
		const meta = (await this.fetchJson(`https://raw.githubusercontent.com/${owner}/${name}/${ref}/package.json`)) as Meta | undefined;
		const tree = await this.fetchJson(`https://api.github.com/repos/${owner}/${name}/git/trees/${ref}?recursive=1`);
		const files = Array.isArray(tree?.tree) ? (tree.tree as { path: string; type: string }[]).filter((f) => f.type === "blob").map((f) => f.path) : undefined;
		if (!meta && !files) return { ok: false, kind, ...empty, contentsKnown: false, error: `Can't find github.com/${owner}/${name}.` };
		return { ok: true, kind, ...metaFields(meta ?? { name }), ...contents(meta?.pi, files ?? []), contentsKnown: Boolean(meta?.pi || files) };
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

	/** One extension, skill, template or theme on or off (pi's filter form: `-path` leaves out one exact path). */
	setResource(source: string, kind: Kind, path: string, enabled: boolean): Promise<void> {
		return this.run(async () => {
			const { settings, packages } = this.manager();
			const entries = settings.getPackages();
			const i = entries.findIndex((e) => sourceOf(e) === source);
			if (i < 0) throw new EngineError("NOT_FOUND", `No package ${source}`);
			const root = packages.listConfiguredPackages().find((p) => p.source === source)?.installedPath;
			const rel = root && isAbsolute(path) ? relative(root, path) : path;
			const entry: Record<string, unknown> = typeof entries[i] === "object" ? { ...(entries[i] as object) } : { source };
			const current = Array.isArray(entry[kind]) ? (entry[kind] as string[]).filter((p) => p !== `-${rel}` && p !== `+${rel}`) : [];
			if (!enabled) current.push(`-${rel}`);
			if (current.length) entry[kind] = current;
			else delete entry[kind];
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

type Meta = { name?: string; version?: string; description?: string; author?: string | { name?: string }; pi?: Record<string, unknown> };

function readMeta(dir: string): Meta {
	try {
		return JSON.parse(readFileSync(join(dir, "package.json"), "utf8")) as Meta;
	} catch {
		return { name: basename(dir) };
	}
}

function metaFields(meta: Meta) {
	const author = typeof meta.author === "string" ? meta.author.replace(/\s*[<(].*$/, "") : meta.author?.name;
	return { ...(meta.name ? { name: meta.name } : {}), ...(meta.version ? { version: meta.version } : {}), ...(meta.description ? { description: meta.description } : {}), ...(author ? { author } : {}) };
}

export function kindOf(source: string): "npm" | "git" | "local" {
	if (source.startsWith("npm:")) return "npm";
	if (source.startsWith("git:") || /^https?:\/\//.test(source) || /^(github|gitlab)\.com\//.test(source)) return "git";
	if (/^[./~]/.test(source) || isAbsolute(source)) return "local";
	return "npm";
}

/** "npm:@scope/name@1.2.0" → its name, version, and whether it's pinned. */
export function npmSpec(source: string): { name: string; version?: string; pinned: boolean } | undefined {
	const s = source.replace(/^npm:/, "").trim();
	const at = s.startsWith("@") ? s.indexOf("@", 1) : s.indexOf("@");
	const name = at > 0 ? s.slice(0, at) : s;
	const version = at > 0 ? s.slice(at + 1) : undefined;
	if (!/^(@[a-z0-9._-]+\/)?[a-z0-9._-]+$/i.test(name)) return undefined;
	return { name, ...(version ? { version } : {}), pinned: Boolean(version && /^\d/.test(version)) };
}

const encodeName = (name: string) => name.replace("/", "%2F");

function newer(a: string, b: string): boolean {
	const pa = a.split(/[.-]/).map((x) => Number.parseInt(x, 10) || 0);
	const pb = b.split(/[.-]/).map((x) => Number.parseInt(x, 10) || 0);
	for (let i = 0; i < 3; i++) if ((pa[i] ?? 0) !== (pb[i] ?? 0)) return (pa[i] ?? 0) > (pb[i] ?? 0);
	return false;
}

/** Files under a folder (relative), skipping node_modules and dot folders; enough to see what a package holds. */
function walk(dir: string, prefix = "", out: string[] = []): string[] {
	for (const name of readdirSync(dir)) {
		if (name === "node_modules" || name.startsWith(".")) continue;
		const path = join(dir, name);
		const rel = prefix ? `${prefix}/${name}` : name;
		if (statSync(path).isDirectory()) {
			if (out.length < 2000) walk(path, rel, out);
		} else out.push(rel);
	}
	return out;
}

/**
 * What's in a package, by name: from its `pi` manifest when it has one (paths, folders or simple globs), else from
 * pi's conventional folders (extensions/, skills/<name>/SKILL.md, prompts/*.md, themes/*.json).
 */
function contents(manifest: Record<string, unknown> | undefined, files: readonly string[]) {
	const roots = (kind: string, fallback: string) => {
		const list = manifest && Array.isArray(manifest[kind]) ? (manifest[kind] as string[]) : manifest ? [] : [fallback];
		return list.filter((p) => !p.startsWith("!")).map((p) => p.replace(/^\.\//, "").replace(/\/?\*.*$/, "").replace(/\/$/, ""));
	};
	const under = (kind: string, fallback: string, test: RegExp) => {
		const r = roots(kind, fallback);
		return files.filter((f) => r.some((root) => f === root || f.startsWith(`${root}/`)) && test.test(f));
	};
	const strip = (f: string) => basename(f).replace(/\.[^.]+$/, "");
	const extensions = under("extensions", "extensions", /\.(ts|js|mjs)$/)
		.filter((f) => !/\.(test|spec|d)\.[tj]s$/.test(f))
		.map((f) => (/^index\.[tj]s$/.test(basename(f)) ? basename(f.replace(/\/index\.[tj]s$/, "")) : strip(f)));
	const skills = under("skills", "skills", /(^|\/)SKILL\.md$/).map((f) => basename(f.replace(/\/SKILL\.md$/, "")));
	const prompts = under("prompts", "prompts", /\.md$/).map(strip);
	const themes = under("themes", "themes", /\.json$/).map(strip);
	return { extensions: [...new Set(extensions)], skills: [...new Set(skills)], prompts: [...new Set(prompts)], themes: [...new Set(themes)] };
}
