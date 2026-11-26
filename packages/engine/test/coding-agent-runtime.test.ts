import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { ApprovalMode } from "@piopio/protocol";
import { expect, test } from "vitest";
import { CodingAgentRuntime, type CodingAgentOptions, type Input } from "../src/runtimes/coding-agent-runtime.js";

// What every coding agent's conversation does the same way (re-audit 2026-11-25 P2: Claude Code and ACP had a copy
// each). A stand-in agent that answers when told to.

class FakeAgent extends CodingAgentRuntime {
	sent: string[] = [];
	interrupted = 0;
	settings: string[] = [];
	closed = false;
	protected readonly agentName = "Fake";
	protected readonly provider = "fake-agent";
	static open(options: CodingAgentOptions): FakeAgent {
		return new FakeAgent(options);
	}
	protected async send(input: Input): Promise<void> {
		if (input.text === "explode") throw new Error("not signed in");
		this.sent.push(input.text);
	}
	/** The agent's turn ends: an answer, then the shared ending. */
	answer(text: string): void {
		this.stored.messages.push({ role: "assistant", content: [{ type: "text", text }], timestamp: Date.now() } as never);
		this.save();
		this.finishTurn();
	}
	announce(id: string, name: string, args: Record<string, unknown>): void {
		this.piopioCalls.push({ id, name, input: JSON.stringify(args) });
	}
	matched(name: string, args: Record<string, unknown>): string {
		return this.callIdFor(name, args);
	}
	isStopping(): boolean {
		return this.stopping;
	}
	protected endAssistant(): void {}
	protected armIdle(): void {}
	protected endIdle(): void {}
	protected async interrupt(): Promise<void> {
		this.interrupted++;
	}
	protected async setAgentModel(id: string): Promise<void> {
		this.settings.push(`model ${id}`);
	}
	protected async setAgentThinking(): Promise<void> {
		this.settings.push(`thinking ${this.thinking ?? "default"}`);
	}
	protected async setAgentMode(mode: ApprovalMode): Promise<void> {
		this.settings.push(`mode ${mode}`);
	}
	protected async closeAgent(): Promise<void> {
		this.closed = true;
	}
}

const options = (file = join(mkdtempSync(join(tmpdir(), "cagent-")), "t.json")): CodingAgentOptions => ({
	ref: { kind: "thread", id: "thr_1" },
	model: { provider: "fake-agent", id: "fake-1" },
	file,
	approvalMode: () => "auto_edit",
});

test("a message while it works waits for the turn, then goes; one that may not wait is refused", async () => {
	const agent = FakeAgent.open(options());
	expect(await agent.submit("first", {})).toEqual({ disposition: "started" });
	expect(await agent.submit("second", { whenBusy: "followUp" })).toEqual({ disposition: "queued" });
	expect(agent.snapshot().state.queue?.map((q) => q.text)).toEqual(["second"]);
	await expect(agent.submit("now", { whenBusy: "reject" })).rejects.toThrow("Fake is still working.");
	agent.answer("one");
	await Promise.resolve();
	expect(agent.sent).toEqual(["first", "second"]);
	expect(agent.snapshot().state.queue).toEqual([]);
	agent.answer("two");
	expect(agent.snapshot().state.status).toBe("idle");
});

test("the transcript is Piopio's copy: a reopened conversation has it", async () => {
	const o = options();
	const agent = FakeAgent.open(o);
	await agent.submit("hello", {});
	agent.answer("hi");
	const again = FakeAgent.open(o);
	expect(again.snapshot().items.map((i) => i.kind)).toEqual(["user", "assistant"]);
});

test("a turn that can't start says why, and the messages that waited go with it", async () => {
	const agent = FakeAgent.open(options());
	await agent.submit("explode", {});
	const last = agent.snapshot().items.at(-1);
	expect(last?.kind === "system" && last.text).toBe("Fake: not signed in");
	expect(agent.snapshot().state.status).toBe("idle");
	expect(await agent.submit("again", {})).toEqual({ disposition: "started" });
});

test("Stop interrupts the agent and drops what waited; the next turn's error isn't taken for the stop", async () => {
	const agent = FakeAgent.open(options());
	await agent.submit("long", {});
	await agent.submit("later", {});
	await agent.abort();
	expect(agent.interrupted).toBe(1);
	expect(agent.isStopping()).toBe(true);
	agent.answer("stopped");
	expect(agent.isStopping()).toBe(false);
	expect(agent.sent).toEqual(["long"]);
});

test("a run of Piopio's tools is matched to the agent's call by name and arguments, else by name", () => {
	const agent = FakeAgent.open(options());
	agent.announce("call_a", "remember", { fact: "a" });
	agent.announce("call_b", "remember", { fact: "b" });
	expect(agent.matched("remember", { fact: "b" })).toBe("call_b");
	expect(agent.matched("remember", { fact: "z" })).toBe("call_a");
	expect(agent.matched("remember", { fact: "a" })).toMatch(/^piopio-/);
});

test("settings go to the agent; another provider's model can't take the conversation over", async () => {
	const agent = FakeAgent.open(options());
	await agent.configure({ model: { provider: "fake-agent", id: "fake-2" }, thinking: "high", approvalMode: "read_only" });
	expect(agent.settings).toEqual(["model fake-2", "thinking high", "mode read_only"]);
	expect(agent.snapshot().state).toMatchObject({ model: { id: "fake-2" }, thinking: "high", approvalMode: "read_only" });
	await expect(agent.configure({ model: { provider: "openrouter", id: "x" } })).rejects.toThrow("This conversation runs in Fake. Start a new conversation to use another model.");
	await agent.close();
	expect(agent.closed).toBe(true);
});
