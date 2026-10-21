/**
 * Skills and prompt templates in Threads, Spaces and Agents (07-shared §6.1 EX4). pi-durable can't load pi
 * extensions, but skills and templates are text: skills are listed in the system prompt and read on demand with
 * `read_skill`; templates are `/commands` the engine expands before sending. Both come from the user's pi folder
 * (`~/.pi/agent/skills`, `prompts`) and the user's enabled pi packages, as the pi CLI finds them.
 */
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { homedir } from "node:os";
import { basename, join, relative, resolve } from "node:path";
import { Type } from "@earendil-works/pi-ai";
import { DefaultPackageManager, formatSkillsForPrompt, loadSkills, SettingsManager, type Skill } from "@earendil-works/pi-coding-agent";
import { defineExtension, defineTool, section } from "@earendil-works/pi-durable";
import type { Result } from "@piopio/protocol";

type SessionCommand = Result<"sessions.commands">["commands"][number];

export const SKILLS_EXTENSION = "piopio-skills";
const MAX_SKILL_CHARS = 60_000;

export type Template = { name: string; description: string; hint?: string; body: string };

export class ChatResources {
	private skills: Skill[] = [];
	private templates: Template[] = [];
	private loading?: Promise<void>;

	constructor(private readonly agentDir: string) {}

	/** Reads skills and templates again (after a package change). */
	reload(): Promise<void> {
		this.loading = this.load().catch(() => undefined);
		return this.loading;
	}

	ready(): Promise<void> {
		return (this.loading ??= this.load().catch(() => undefined));
	}

	private async load(): Promise<void> {
		const settings = SettingsManager.create(homedir(), this.agentDir);
		const packages = new DefaultPackageManager({ cwd: homedir(), agentDir: this.agentDir, settingsManager: settings });
		const resolved = await packages.resolve(async () => "skip");
		const skillPaths = resolved.skills.filter((r) => r.enabled).map((r) => r.path);
		this.skills = loadSkills({ cwd: homedir(), agentDir: this.agentDir, skillPaths, includeDefaults: true }).skills;
		const promptFiles = new Set(resolved.prompts.filter((r) => r.enabled).map((r) => r.path));
		const own = join(this.agentDir, "prompts");
		if (existsSync(own)) for (const f of readdirSync(own).filter((f) => f.endsWith(".md"))) promptFiles.add(join(own, f));
		this.templates = [...promptFiles].flatMap((f) => {
			try {
				return [parseTemplate(f)];
			} catch {
				return [];
			}
		});
	}

	commands(): SessionCommand[] {
		return [
			...this.templates.map((t) => ({ name: t.name, description: t.description, kind: "template" as const, ...(t.hint ? { hint: t.hint } : {}) })),
			...this.skills.map((s) => ({ name: `skill:${s.name}`, description: s.description, kind: "skill" as const })),
		];
	}

	/**
	 * `/name args` → the template's text with its arguments, or `/skill:name request` → the skill's instructions
	 * plus the request. Undefined when the text isn't a known command.
	 */
	expand(text: string): string | undefined {
		const m = /^\/([\w:.-]+)(?:\s+([\s\S]*))?$/.exec(text.trim());
		if (!m) return undefined;
		const [, name, rest = ""] = m;
		if (name!.startsWith("skill:")) {
			const skill = this.skills.find((s) => s.name === name!.slice(6));
			if (!skill) return undefined;
			return `<skill name="${skill.name}">\n${readSkill(skill)}\n</skill>\n\n${rest || `Use the ${skill.name} skill.`}`;
		}
		const template = this.templates.find((t) => t.name === name);
		return template ? substitute(template.body, splitArgs(rest)) : undefined;
	}

	/** The pi-durable extension: the skills list in the prompt, and `read_skill`. */
	extension() {
		const readTool = defineTool({
			name: "read_skill",
			description: "Read a skill's instructions (SKILL.md), or another file of the skill, before following it.",
			parameters: Type.Object({ name: Type.String({ description: "The skill's name" }), file: Type.Optional(Type.String({ description: "A file inside the skill, relative to it. Default: SKILL.md" })) }),
			execute: async (args) => {
				const skill = this.skills.find((s) => s.name === args.name);
				if (!skill) return { output: [{ type: "text", text: `No skill “${args.name}”. Skills: ${this.skills.map((s) => s.name).join(", ") || "none"}.` }], isError: true };
				if (!args.file) return { output: [{ type: "text", text: readSkill(skill) }] };
				const target = resolve(skill.baseDir, args.file);
				if (relative(skill.baseDir, target).startsWith("..") || !existsSync(target) || !statSync(target).isFile()) {
					return { output: [{ type: "text", text: `No file ${args.file} in the skill.` }], isError: true };
				}
				return { output: [{ type: "text", text: readFileSync(target, "utf8").slice(0, MAX_SKILL_CHARS) }] };
			},
		});
		return defineExtension({
			name: SKILLS_EXTENSION,
			tools: [readTool],
			sections: [
				section("skills", () => {
					const listed = this.skills.filter((s) => !s.disableModelInvocation);
					if (!listed.length) return undefined;
					return `${formatSkillsForPrompt(listed, "indirect")}\nLoad a skill with read_skill before following it.`;
				}),
			],
		});
	}
}

function readSkill(skill: Skill): string {
	return readFileSync(skill.filePath, "utf8").slice(0, MAX_SKILL_CHARS);
}

/** A prompt template: optional frontmatter (`description`, `argument-hint`), then the body. */
export function parseTemplate(file: string): Template {
	const raw = readFileSync(file, "utf8");
	const front = /^---\n([\s\S]*?)\n---\n?/.exec(raw);
	const meta: Record<string, string> = {};
	for (const line of (front?.[1] ?? "").split("\n")) {
		const kv = /^([\w-]+):\s*(.*)$/.exec(line);
		if (kv) meta[kv[1]!] = kv[2]!.replace(/^["']|["']$/g, "");
	}
	const body = front ? raw.slice(front[0].length) : raw;
	const firstLine = body.split("\n").find((l) => l.trim())?.trim() ?? "";
	return { name: basename(file, ".md"), description: meta.description ?? firstLine.slice(0, 100), ...(meta["argument-hint"] ? { hint: meta["argument-hint"] } : {}), body: body.trim() };
}

/** Splits arguments like a shell: spaces, with "quoted strings" kept together. */
export function splitArgs(text: string): string[] {
	return [...text.matchAll(/"([^"]*)"|'([^']*)'|(\S+)/g)].map((m) => m[1] ?? m[2] ?? m[3]!);
}

/** `$1`…`$9`, `$@` and `$ARGUMENTS` (all of them), `${@:N}` (from the Nth on). */
export function substitute(body: string, args: string[]): string {
	return body
		.replace(/\$\{@:(\d+)\}/g, (_, n: string) => args.slice(Number(n) - 1).join(" "))
		.replace(/\$ARGUMENTS|\$@/g, args.join(" "))
		.replace(/\$(\d)/g, (_, n: string) => args[Number(n) - 1] ?? "");
}

