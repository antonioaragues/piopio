/**
 * The engine's `home.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `home.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { type Params, type Result } from "@piopio/protocol";
import { PIOPIO, systemZone } from "../automations/model.js";
import { buildAgenda } from "../agenda.js";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function homeHandlers(engine: Engine): Handlers<"home"> {
	return {
		"home.agenda": async (params, _call) => {
			const p = params as Params<"home.agenda">;
			// Messages held by quiet hours or limits, across agents.
			let held = 0;
			for (const a of engine.sessions.list("agent")) held += (await engine.sessions.agents.agentRuns(a.ref).catch(() => undefined))?.outbox.length ?? 0;
			const all = engine.projects.list();
			const agents = new Map(engine.sessions.agents.agentList().map((a) => [a.id, a.name]));
			const automations = engine.automations.list().map((a) => ({
				id: a.id,
				name: a.name,
				on: a.on,
				label: engine.automations.summary(a).when,
				...(a.next ? { next: a.next } : {}),
				enabled: a.enabled,
				source:
					a.runsAs !== PIOPIO
						? { kind: "agent" as const, id: a.runsAs, name: agents.get(a.runsAs) ?? "An agent" }
						: a.project
							? { kind: "project" as const, id: a.project, name: all.find((x) => x.id === a.project)?.name ?? "A project" }
							: { kind: "piopio" as const, id: PIOPIO, name: "Piopio" },
			}));
			const runs = await engine.automations.runsOf(undefined, 500);
			const boards = engine.work.list().flatMap((w) => {
				const name = all.find((x) => x.id === w.project)?.name;
				return name ? [{ project: { id: w.project, name }, tasks: w.tasks }] : [];
			});
			return buildAgenda({ now: Date.now(), tz: systemZone(), ...(p.since ? { since: Date.parse(p.since) } : {}), automations, runs, boards, held }) satisfies Result<"home.agenda">;
		},
	};
}
