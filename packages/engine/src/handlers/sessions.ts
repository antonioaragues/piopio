/**
 * The engine's `sessions.*` methods (docs/spec/03-engine-protocol.md), one handler each. server.ts checks the params
 * against the protocol before calling them. A new `sessions.*` method in packages/protocol goes here: handlers/index.ts
 * doesn't compile until it has one.
 */
import { keepAttachments } from "../attachment-files.js";
import { randomUUID } from "node:crypto";
import { type Params, type Result } from "@piopio/protocol";
import { EngineError } from "../models.js";
import type { Runtime } from "../runtimes/runtime.js";
import { StepsView } from "../timeline/steps.js";
import { DeltaBatcher } from "../timeline/delta-batcher.js";
import { fold } from "../timeline/fold.js";
import type { Engine } from "../server.js";
import type { Handlers } from "./types.js";

export function sessionsHandlers(engine: Engine): Handlers<"sessions"> {
	return {
		"sessions.list": async (params, _call) => {
			const p = params as Params<"sessions.list">;
			return { sessions: engine.sessions.list(p.kind) } satisfies Result<"sessions.list">;
		},
		"sessions.continueIn": async (params, _call) => {
			const p = params as Params<"sessions.continueIn">;
			return { ref: await engine.sessions.continueIn(p.ref, p.cwd, p.approvalMode) } satisfies Result<"sessions.continueIn">;
		},
		"sessions.create": async (params, _call) => {
			const p = params as Params<"sessions.create">;
			return { ref: await engine.sessions.create(p) } satisfies Result<"sessions.create">;
		},
		"sessions.keep": async (params, _call) => {
			await engine.sessions.keep((params as Params<"sessions.keep">).ref);
			return {} satisfies Result<"sessions.keep">;
		},
		"sessions.open": async (params, _call) => {
			const p = params as Params<"sessions.open">;
			const snapshot = (await engine.sessions.runtime(p.ref)).snapshot();
			return (p.fold ? { ...snapshot, items: fold(snapshot.items) } : snapshot) satisfies Result<"sessions.open">;
		},
		"sessions.subscribe": async (params, { conn, owned }) => {
			const p = params as Params<"sessions.subscribe">;
			const runtime = await engine.sessions.runtime(p.ref);
			const subscriptionId = `sub_${randomUUID().slice(0, 8)}`;
			let seq = 0;
			// Folded: this subscription sees a turn's tool calls as one steps item.
			const steps = p.fold ? new StepsView(fold) : undefined;
			const snapshot = runtime.snapshot();
			const first = steps ? { ...snapshot, items: steps.snapshot(snapshot.items) } : snapshot;
			// A notification per token is a JSON line and a main-thread hop on the Mac per token: deltas go out a frame at a time.
			const batcher = new DeltaBatcher((events) => conn.notify("session.events", { subscriptionId, seq: ++seq, events }));
			let current = runtime;
			let unsubscribe = runtime.onEvents((events) => {
				batcher.push(steps ? steps.events(events) : events);
			});
			const off = () => {
				unsubscribe();
				batcher.dispose();
				engine.rebinders.delete(subscriptionId);
			};
			engine.subscriptions.set(subscriptionId, off);
			// The conversation's runtime was replaced: listen to the new one, starting from its snapshot.
			if (!p.ref.conversationId) {
				engine.rebinders.set(subscriptionId, {
					refId: p.ref.id,
					rebind: async () => {
						const next = await engine.sessions.runtime(p.ref);
						if (next === current || !engine.subscriptions.has(subscriptionId)) return;
						unsubscribe();
						current = next;
						const snap = next.snapshot();
						batcher.push([{ type: "resnapshot", snapshot: steps ? { ...snap, items: steps.snapshot(snap.items) } : snap }]);
						unsubscribe = next.onEvents((events) => batcher.push(steps ? steps.events(events) : events));
					},
				});
			}
			owned.add(subscriptionId);
			return { subscriptionId, snapshot: first } satisfies Result<"sessions.subscribe">;
		},
		"sessions.unsubscribe": async (params, { owned }) => {
			const p = params as Params<"sessions.unsubscribe">;
			engine.subscriptions.get(p.subscriptionId)?.();
			engine.subscriptions.delete(p.subscriptionId);
			owned.delete(p.subscriptionId);
			return {};
		},
		"sessions.submit": async (params, _call) => {
			const p = params as Params<"sessions.submit">;
			// A subagent still queued: your words join its brief; it starts in its turn (docs/spec/37).
			if (engine.sessions.children.addToQueuedBrief(p.ref, p.input.text)) return { accepted: true, disposition: "queued" } satisfies Result<"sessions.submit">;
			const runtime = await engine.sessions.runtime(p.ref);
			const isFirst = runtime.snapshot().items.length === 0;
			// An app's conversation: the page's changes from now on are this request's, for Undo (docs/spec/35 §15).
			const appPath = engine.apps.appOf(p.ref.id);
			if (appPath) engine.apps.noteRequest(appPath, p.input.text);
			// Your own words (docs/spec/24 §5): side conversations may wake this one again; one you drive doesn't wake its parent.
			engine.sessions.youWrote(p.ref);
			const { disposition } = await runtime.submit(p.input.text, {
				whenBusy: p.whenBusy ?? "followUp",
				...(p.clientRequestId ? { requestId: p.clientRequestId } : {}),
				...(p.input.attachments ? { attachments: keepAttachments(engine.options.paths.home, p.ref.id, p.input.attachments) } : {}),
			});
			engine.sessions.touch(p.ref, isFirst ? p.input.text : undefined);
			return { accepted: true, disposition } satisfies Result<"sessions.submit">;
		},
		"sessions.abort": async (params, _call) => {
			const p = params as Params<"sessions.abort">;
			await (await engine.sessions.runtime(p.ref)).abort();
			return {};
		},
		"sessions.edit": async (params, _call) => {
			const p = params as Params<"sessions.edit">;
			await capability(engine, p.ref, "edit").then((r) => r.edit!(p.itemId, p.text));
			engine.sessions.touch(p.ref);
			return {};
		},
		"sessions.regenerate": async (params, _call) => {
			const p = params as Params<"sessions.regenerate">;
			await capability(engine, p.ref, "regenerate").then((r) => r.regenerate!(p.itemId));
			engine.sessions.touch(p.ref);
			return {};
		},
		"sessions.switchBranch": async (params, _call) => {
			const p = params as Params<"sessions.switchBranch">;
			await capability(engine, p.ref, "switchBranch").then((r) => r.switchBranch!(p.branch));
			return {};
		},
		"sessions.fork": async (params, _call) => {
			const p = params as Params<"sessions.fork">;
			return { ref: await engine.sessions.fork(p.ref, p.itemId) } satisfies Result<"sessions.fork">;
		},
		"sessions.queue.remove": async (params, _call) => {
			const p = params as Params<"sessions.queue.remove">;
			await capability(engine, p.ref, "removeQueued").then((r) => r.removeQueued!(p.queueId));
			return {};
		},
		"sessions.configure": async (params, _call) => {
			const p = params as Params<"sessions.configure">;
			await engine.sessions.configure(p.ref, { ...(p.model ? { model: p.model } : {}), ...(p.thinking ? { thinking: p.thinking } : {}), ...(p.web !== undefined ? { web: p.web } : {}), ...(p.approvalMode ? { approvalMode: p.approvalMode } : {}), ...(p.planMode !== undefined ? { planMode: p.planMode } : {}), ...(p.toolsOff ? { toolsOff: p.toolsOff } : {}) });
			return {};
		},
		"sessions.rename": async (params, _call) => {
			const p = params as Params<"sessions.rename">;
			engine.sessions.rename(p.ref, p.title);
			return {};
		},
		"sessions.delete": async (params, _call) => {
			const p = params as Params<"sessions.delete">;
			await engine.sessions.delete(p.ref);
			return {};
		},
		"sessions.export": async (params, _call) => {
			const p = params as Params<"sessions.export">;
			return (await engine.sessions.export(p.ref, p.format)) satisfies Result<"sessions.export">;
		},
		"sessions.agentDraft": async (params, _call) => {
			const p = params as Params<"sessions.agentDraft">;
			return (await engine.sessions.agentDraft(p.ref)) satisfies Result<"sessions.agentDraft">;
		},
		"sessions.changes": async (params, _call) => {
			const p = params as Params<"sessions.changes">;
			return (await (await engine.sessions.build(p.ref)).changes(p.since)) satisfies Result<"sessions.changes">;
		},
		"sessions.diff": async (params, _call) => {
			const p = params as Params<"sessions.diff">;
			return { patch: await (await engine.sessions.build(p.ref)).diff(p.path, p.since) } satisfies Result<"sessions.diff">;
		},
		"sessions.restore": async (params, _call) => {
			const p = params as Params<"sessions.restore">;
			return { files: await (await engine.sessions.build(p.ref)).restore(p.checkpointId, p.paths, p.dryRun ?? false) } satisfies Result<"sessions.restore">;
		},
		"sessions.commands": async (params, _call) => {
			const p = params as Params<"sessions.commands">;
			if (p.ref.kind === "agent") return { commands: await engine.sessions.chatCommands() } satisfies Result<"sessions.commands">;
			return { commands: (await engine.sessions.build(p.ref)).commands() } satisfies Result<"sessions.commands">;
		},
		"sessions.rewind": async (params, _call) => {
			const p = params as Params<"sessions.rewind">;
			return (await (await engine.sessions.build(p.ref)).rewind(p.itemId, p.files, p.dryRun ?? false)) satisfies Result<"sessions.rewind">;
		},
		"sessions.tree": async (params, _call) => {
			const p = params as Params<"sessions.tree">;
			return { nodes: (await engine.sessions.build(p.ref)).tree() } satisfies Result<"sessions.tree">;
		},
		"sessions.navigate": async (params, _call) => {
			const p = params as Params<"sessions.navigate">;
			return (await (await engine.sessions.build(p.ref)).navigate(p.entryId)) satisfies Result<"sessions.navigate">;
		},
		"sessions.compact": async (params, _call) => {
			const p = params as Params<"sessions.compact">;
			await (await engine.sessions.build(p.ref)).compact();
			return {};
		},
		"sessions.pr.draft": async (params, _call) => {
			const p = params as Params<"sessions.pr.draft">;
			return (await engine.sessions.prs.draft(p.ref)) satisfies Result<"sessions.pr.draft">;
		},
		"sessions.pr.create": async (params, _call) => {
			const p = params as Params<"sessions.pr.create">;
			return { pr: await engine.sessions.prs.create(p.ref, { title: p.title, body: p.body, ...(p.base ? { base: p.base } : {}), ...(p.draft ? { draft: true } : {}) }) } satisfies Result<"sessions.pr.create">;
		},
		"sessions.pr.get": async (params, _call) => {
			const p = params as Params<"sessions.pr.get">;
			return { pr: await engine.sessions.prs.status(p.ref) } satisfies Result<"sessions.pr.get">;
		},
		"sessions.pr.address": async (params, _call) => {
			const p = params as Params<"sessions.pr.address">;
			await engine.sessions.prs.address(p.ref, p.what);
			return {} satisfies Result<"sessions.pr.address">;
		},
		"sessions.side.answer": async (params, _call) => {
			const p = params as Params<"sessions.side.answer">;
			return (await engine.sessions.children.answerSide(p.ref, p.id, p.choice)) satisfies Result<"sessions.side.answer">;
		},
		"sessions.side.start": async (params, _call) => {
			const p = params as Params<"sessions.side.start">;
			const child = await engine.sessions.children.startSide(p.ref, { brief: p.brief, ...(p.title ? { title: p.title } : {}) }, "manual");
			return { ref: child.ref } satisfies Result<"sessions.side.start">;
		},
		"sessions.finish": async (params, _call) => {
			const p = params as Params<"sessions.finish">;
			await engine.sessions.finish(p.ref, p.action);
			return {};
		},
		"sessions.processOutput": async (params, _call) => {
			const p = params as Params<"sessions.processOutput">;
			return (await engine.sessions.build(p.ref)).processOutput(p.id, p.since ?? 0) satisfies Result<"sessions.processOutput">;
		},
		"sessions.processStop": async (params, _call) => {
			const p = params as Params<"sessions.processStop">;
			return (await (await engine.sessions.build(p.ref)).processStop(p.id)) satisfies Result<"sessions.processStop">;
		},
		"sessions.review": async (params, _call) => {
			const p = params as Params<"sessions.review">;
			return { ref: await engine.sessions.review(p.ref, p.pr) } satisfies Result<"sessions.review">;
		},
		"sessions.reviewFinding": async (params, _call) => {
			const p = params as Params<"sessions.reviewFinding">;
			engine.sessions.reviewFinding(p.ref, p.id, p.state);
			return {} satisfies Result<"sessions.reviewFinding">;
		},
		"sessions.respond": async (params, _call) => {
			const p = params as Params<"sessions.respond">;
			await engine.sessions.respond(p.ref, p.promptId, p.response);
			return {};
		},
		"sessions.decide": async (params, _call) => {
			const p = params as Params<"sessions.decide">;
			return { status: await engine.sessions.decide(p.ref, p.approvalId, { approve: p.approve, ...(p.always ? { always: true } : {}), ...(p.reason ? { reason: p.reason } : {}) }) } satisfies Result<"sessions.decide">;
		},
	};
}

async function capability(engine: Engine, ref: Params<"sessions.open">["ref"], name: "edit" | "regenerate" | "switchBranch" | "removeQueued"): Promise<Runtime> {
	const runtime = await engine.sessions.runtime(ref);
	if (!runtime[name]) throw new EngineError("INVALID", `${ref.kind} sessions don't support ${name} yet.`);
	return runtime;
}
