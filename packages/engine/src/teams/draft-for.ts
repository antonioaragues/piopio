/**
 * "A team for piopio" (docs/spec/21 D7, design 5b-2): a team drafted for a project from what's in it and what was
 * asked. The project is read for its language, checks and git; the background model drafts the members, else the
 * development template does for code (any other work gets the plain draft). Your agents are suggested where their job
 * fits a member's.
 */
import { basename } from "node:path";
import type { ConsultAgent } from "../consult.js";
import { draftTeam, type TeamDraft } from "./library.js";
import { fitCheck, type FitCheck } from "./fit.js";
import { TEAM_TEMPLATES, type RoleKind } from "./templates.js";

export type DraftFor = { draft: TeamDraft; found: FitCheck; suggestions: { role: string; agent: string; name: string }[] };

/** Which of your agents fit a kind of work, from their name and line. */
const FITS: Partial<Record<RoleKind, RegExp>> = {
	review: /\b(review|reviewer|reviews|qa|quality|test|tester|audit|revis)/i,
	write: /\b(build|builder|code|coder|develop|developer|engineer|writer|write)/i,
};

export async function draftFor(cwd: string, request: string, complete: ((system: string, prompt: string) => Promise<string | undefined>) | undefined, agents: ConsultAgent[]): Promise<DraftFor> {
	const found = fitCheck(cwd);
	const project = basename(cwd);
	const code = Boolean(found.language || found.checks);
	const about = [
		`A team for the project “${project}”.`,
		found.language ? `It's written in ${found.language}.` : "",
		found.checks ? `Its checks: ${found.checks}.` : "",
		code && found.git ? "Software work: members work on branches, a CI member merges and runs the checks." : "",
		request.trim() ? `What it's asked to do first: ${request.trim()}` : "",
	].filter(Boolean).join(" ");
	let draft = await draftTeam(about, complete);
	// The plain draft (no background model) reads a description of who's on the team; for code, the template is better.
	const plain = draft.description.startsWith("Made from your description");
	if (plain && code) {
		const t = TEAM_TEMPLATES.find((x) => x.id === "development")!;
		draft = { name: `${project[0]!.toUpperCase()}${project.slice(1)} team`, description: t.description, style: t.style, instructions: t.instructions ?? "", roles: t.roles.map((r) => ({ ...r })) };
	} else if (plain) {
		draft = { ...draft, name: `${project[0]!.toUpperCase()}${project.slice(1)} team` };
	}
	// Without checks there's nothing for a CI member to run.
	if (!found.checks && !found.git) draft = { ...draft, roles: draft.roles.filter((r) => r.kind !== "integrate") };
	const suggestions: DraftFor["suggestions"] = [];
	const taken = new Set<string>();
	// The reviewer first: "reviews code" fits a builder's words too.
	for (const role of [...draft.roles].sort((x, y) => Number(y.kind === "review") - Number(x.kind === "review"))) {
		const fits = FITS[role.kind];
		if (!fits) continue;
		const agent = agents.find((a) => !taken.has(a.id) && fits.test(`${a.name} ${a.description ?? ""}`));
		if (!agent) continue;
		taken.add(agent.id);
		suggestions.push({ role: role.id, agent: agent.id, name: agent.name });
	}
	return { draft, found, suggestions };
}
