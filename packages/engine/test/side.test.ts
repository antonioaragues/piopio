import { execFileSync } from "node:child_process";
import { existsSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, expect, test } from "vitest";
import { enginePaths } from "../src/paths.js";
import { Engine } from "../src/server.js";
import { TestClient } from "./client.js";

// Side conversations, SD1–SD2 (docs/spec/24): started when you ask for separate work or with /side; each one works
// beside its parent, in a worktree in a git project, and reports back with a note that may wake the parent.

type Ref = { kind: string; id: string };
type Summary = { ref: Ref; title: string; cwd?: string; worktree?: { branch: string }; side?: { parent: { id: string; title: string }; how: string; state: string; line?: string } };

const open: { engine: Engine; client: TestClient }[] = [];
afterEach(async () => {
	for (const o of open.splice(0)) {
		o.client.close();
		await o.engine.stop();
	}
});

async function until<T>(get: () => Promise<T> | T, ok: (v: T) => boolean, ms = 30_000): Promise<T> {
	const end = Date.now() + ms;
	for (;;) {
		const v = await get();
		if (ok(v)) return v;
		if (Date.now() > end) throw new Error(`timed out: ${JSON.stringify(v).slice(0, 1500)}`);
		await new Promise((r) => setTimeout(r, 80));
	}
}

async function start() {
	const home = mkdtempSync(join(tmpdir(), "piopio-side-"));
	const paths = enginePaths(home);
	const engine = new Engine({ paths, faux: true, piSessionDir: join(home, "pi-sessions"), piAgentDir: join(home, "pi-agent"), trashDir: join(home, "trash"), agentsDir: join(home, "Agents"), teamsDir: join(home, "Teams"), hooksPort: 0, log: () => {} });
	await engine.listen();
	const client = await TestClient.connect(paths.socket);
	open.push({ engine, client });
	await client.call("engine.hello", { token: readFileSync(paths.tokenFile, "utf8").trim(), client: "test", protocolVersion: "1.0", services: [] });
	return client;
}

function repo(): string {
	const dir = realpathSync(mkdtempSync(join(tmpdir(), "piopio-side-repo-")));
	const git = (...args: string[]) => execFileSync("git", args, { cwd: dir, env: { ...process.env, GIT_AUTHOR_NAME: "T", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "T", GIT_COMMITTER_EMAIL: "t@t" } });
	git("init", "-q", "-b", "main");
	writeFileSync(join(dir, "README.md"), "# App\n");
	git("add", "-A");
	git("commit", "-qm", "init");
	return dir;
}

async function conversation(client: TestClient, cwd: string): Promise<Ref> {
	// Trusted, as your own projects are: Full access needs it (docs/spec/39).
	const { project: added } = (await client.call("projects.add", { path: cwd })) as { project: { id: string } };
	await client.call("projects.configure", { id: added.id, trust: true });
	return ((await client.call("sessions.create", { kind: "build", cwd, approvalMode: "full_auto" })) as { ref: Ref }).ref;
}

const sessions = async (client: TestClient) => (await client.call("sessions.list", { kind: "build" })).sessions as Summary[];
const items = async (client: TestClient, ref: Ref) => (await client.call("sessions.open", { ref })).items as { kind: string; text?: string; level?: string; tool?: string; status?: string; output?: string }[];
const sideStart = (args: object) => `call: side_start | ${JSON.stringify(args)}`;

test("asked in words: a side conversation in its own worktree does its task and its note wakes the parent (SD1, SD2)", async () => {
	const client = await start();
	const dir = repo();
	const parent = await conversation(client, dir);
	await client.call("sessions.submit", { ref: parent, input: { text: `Also, do the about page in its own conversation.\n${sideStart({ title: "About page", brief: "write: about.html | <p>About</p>" })}` } });
	const child = await until(() => sessions(client), (s) => s.some((x) => x.side?.state === "done")).then((s) => s.find((x) => x.side)!);
	expect(child).toMatchObject({ title: "About page", side: { parent: { id: parent.id }, how: "asked", state: "done", from: expect.any(String) }, worktree: { branch: expect.stringMatching(/^side\/about-page-/) } });
	// It worked in its worktree; the parent's folder didn't change.
	expect(readFileSync(join(child.cwd!, "about.html"), "utf8")).toContain("About");
	expect(existsSync(join(dir, "about.html"))).toBe(false);
	// Its note woke the parent: a [Side] message, then the parent's answer.
	const said = await until(() => items(client, parent), (xs) => xs.some((i) => i.kind === "user" && i.text?.startsWith("[Side] “About page”")) && xs.at(-1)?.kind === "assistant");
	const note = said.find((i) => i.kind === "user" && i.text?.startsWith("[Side]"))!.text!;
	expect(note).toContain(`(${child.ref.id}) finished. Its work is on ${child.worktree!.branch}, not in this checkout until the user merges it.`);
	// side_read: its state, branch and what it changed.
	await until(async () => ((await client.call("sessions.open", { ref: parent })) as { state: { status: string } }).state.status, (s) => s === "idle");
	await client.call("sessions.submit", { ref: parent, input: { text: `call: side_read | ${JSON.stringify({ id: child.ref.id })}` } });
	const read = await until(() => items(client, parent), (xs) => xs.some((i) => i.tool === "side_read" && i.status === "done"));
	const out = read.find((i) => i.tool === "side_read")!.output!;
	expect(out).toContain(`About page (${child.ref.id}) · done · branch ${child.worktree!.branch}`);
	expect(out).toContain("about.html");
}, 60_000);

test("only on your words: a turn a board update started can't start one, and a stranger's id can't be read", async () => {
	const client = await start();
	const dir = repo();
	const parent = await conversation(client, dir);
	await client.call("sessions.submit", { ref: parent, input: { text: `[Board] T1 is done.\n${sideStart({ title: "Nope", brief: "x" })}\ncall: side_read | ${JSON.stringify({ id: "ses_nope" })}` } });
	const xs = await until(() => items(client, parent), (x) => x.filter((i) => i.kind === "tool" && i.status !== "running").length === 2);
	expect(xs.find((i) => i.tool === "side_start")).toMatchObject({ status: "error", output: expect.stringContaining("only when the user asks for separate work") });
	expect(xs.find((i) => i.tool === "side_read")).toMatchObject({ status: "error", output: expect.stringContaining("isn't one of this conversation's side conversations") });
	expect((await sessions(client)).filter((s) => s.side)).toEqual([]);
}, 30_000);

test("/side by hand; two at once report in one woken turn, once the slower one is done", async () => {
	const client = await start();
	const dir = repo();
	const parent = await conversation(client, dir);
	await client.call("sessions.side.start", { ref: parent, brief: "$ sleep 2\nwrite: slow.txt | slow" });
	await client.call("sessions.side.start", { ref: parent, brief: "write: fast.txt | fast", title: "Fast one" });
	const kids = await until(() => sessions(client), (s) => s.filter((x) => x.side?.state === "done").length === 2).then((s) => s.filter((x) => x.side).sort((a, b) => a.title.localeCompare(b.title)));
	expect(kids.map((k) => [k.title, k.side!.how])).toEqual([["$ sleep 2", "manual"], ["Fast one", "manual"]]);
	const xs = await until(() => items(client, parent), (x) => x.some((i) => i.kind === "user") && x.at(-1)?.kind === "assistant");
	const woke = xs.filter((i) => i.kind === "user");
	expect(woke).toHaveLength(1);
	expect(woke[0]!.text).toContain("“Fast one”");
	expect(woke[0]!.text).toContain("“$ sleep 2”");
}, 60_000);

test("a side conversation you drive yourself reports quietly: a line in the parent, no new turn", async () => {
	const client = await start();
	const dir = repo();
	const parent = await conversation(client, dir);
	const { ref: child } = (await client.call("sessions.side.start", { ref: parent, brief: "write: a.txt | a" })) as { ref: Ref };
	await until(() => items(client, parent), (x) => x.at(-1)?.kind === "assistant");
	await until(async () => ((await client.call("sessions.open", { ref: parent })) as { state: { status: string } }).state.status, (s) => s === "idle");
	const before = (await items(client, parent)).length;
	// You write in the side conversation yourself.
	await client.call("sessions.submit", { ref: child, input: { text: "write: b.txt | b" } });
	const xs = await until(() => items(client, parent), (x) => x.length > before && x.some((i) => i.kind === "system" && i.text?.includes("Message from")));
	expect(xs.slice(before).map((i) => i.kind)).toEqual(["system"]);
	expect(xs.at(-1)).toMatchObject({ kind: "system", text: `Message from ${"write: a.txt | a"} · done` });
}, 60_000);

const answer = (client: TestClient, ref: Ref, id: string, choice: string) => client.call("sessions.side.answer", { ref, id, choice }) as Promise<{ ref?: Ref; askAlways?: boolean }>;
const idle = (client: TestClient, ref: Ref) => until(async () => ((await client.call("sessions.open", { ref })) as { state: { status: string } }).state.status, (s) => s === "idle");
/** The call id of the latest call to this tool in a conversation. */
const callOf = async (client: TestClient, ref: Ref, tool: string, count = 1) => {
	const xs = await until(() => items(client, ref), (x) => x.filter((i) => i.tool === tool && i.status === "done").length >= count);
	return ((xs.filter((i) => i.tool === tool).at(-1)) as unknown as { callId: string }).callId;
};

test("offered (SD3): New conversation starts one from your words; Do it here sends it back; each card answers once; three in a row ask to always start", async () => {
	const client = await start();
	const dir = repo();
	const parent = await conversation(client, dir);
	for (let n = 1; n <= 3; n++) {
		await client.call("sessions.submit", { ref: parent, input: { text: `Also write page ${n}.\ncall: side_offer | ${JSON.stringify({ title: `Page ${n}`, brief: `write: p${n}.html | page ${n}` })}` } });
		const id = await callOf(client, parent, "side_offer", n);
		await idle(client, parent);
		const { ref, askAlways } = await answer(client, parent, id, "new");
		expect(ref).toBeDefined();
		expect(askAlways).toBe(n === 3 ? true : undefined);
		await expect(answer(client, parent, id, "here")).rejects.toThrow(/already has its own conversation/);
		await until(() => sessions(client), (s) => s.find((x) => x.ref.id === ref!.id)?.side?.state === "done");
		await idle(client, parent);
	}
	const kids = (await sessions(client)).filter((s) => s.side);
	expect(kids.map((k) => [k.title, k.side!.how]).sort()).toEqual([["Page 1", "offered"], ["Page 2", "offered"], ["Page 3", "offered"]]);
	// Do it here: the conversation hears it from you, and goes on.
	await client.call("sessions.submit", { ref: parent, input: { text: `Also fix the footer.\ncall: side_offer | ${JSON.stringify({ title: "Footer" })}` } });
	const id = await callOf(client, parent, "side_offer", 4);
	await idle(client, parent);
	expect(await answer(client, parent, id, "here")).toEqual({});
	await until(() => items(client, parent), (x) => x.some((i) => i.kind === "user" && i.text === "Do it here.") && x.at(-1)?.kind === "assistant");
	expect((await sessions(client)).filter((s) => s.side)).toHaveLength(3);
}, 90_000);

test("proposed (SD3): a card you start or dismiss, withdrawn by Piopio, refused when proposals are off; offers refused when they're off", async () => {
	const client = await start();
	const dir = repo();
	const parent = await conversation(client, dir);
	const propose = (title: string) => `call: side_propose | ${JSON.stringify({ title, brief: `write: ${title.toLowerCase()}.txt | ${title}`, why: "Spotted in passing" })}`;
	await client.call("sessions.submit", { ref: parent, input: { text: `${propose("Alpha")}\n${propose("Beta")}\n${propose("Gamma")}\n${propose("Alpha")}` } });
	let xs = await until(() => items(client, parent), (x) => x.filter((i) => i.tool === "side_propose" && i.status !== "running").length === 4);
	expect(xs.filter((i) => i.tool === "side_propose").map((i) => i.status)).toEqual(["done", "done", "done", "error"]);
	type P = { id: string; title: string; why: string; expiresAt: string };
	const proposals = async () => ((await sessions(client)).find((s) => s.ref.id === parent.id) as Summary & { sideProposals?: P[] }).sideProposals ?? [];
	const [alpha, beta, gamma] = await proposals();
	expect(alpha).toMatchObject({ title: "Alpha", why: "Spotted in passing" });
	expect(Date.parse(alpha!.expiresAt) - Date.now()).toBeGreaterThan(6.9 * 86_400_000);
	// Start one, dismiss one, Piopio withdraws the last.
	await idle(client, parent);
	const { ref } = await answer(client, parent, alpha!.id, "start");
	await until(() => sessions(client), (s) => s.find((x) => x.ref.id === ref!.id)?.side?.state === "done");
	expect((await sessions(client)).find((x) => x.ref.id === ref!.id)).toMatchObject({ title: "Alpha", side: { how: "proposed", from: alpha!.id } });
	await answer(client, parent, beta!.id, "dismiss");
	await expect(answer(client, parent, beta!.id, "start")).rejects.toThrow(/gone/);
	await idle(client, parent);
	await client.call("sessions.submit", { ref: parent, input: { text: `call: side_dismiss | ${JSON.stringify({ id: gamma!.id })}` } });
	await until(proposals, (p) => p.length === 0);
	// Settings › Chat: proposals off, offers off.
	await idle(client, parent);
	await client.call("settings.set", { chat: { sidePropose: false, sideOnUnrelated: "off" } });
	await client.call("sessions.submit", { ref: parent, input: { text: `${propose("Delta")}\ncall: side_offer | ${JSON.stringify({ title: "Other" })}` } });
	xs = await until(() => items(client, parent), (x) => x.filter((i) => (i.tool === "side_propose" || i.tool === "side_offer") && i.status !== "running").length === 6);
	expect(xs.filter((i) => i.tool === "side_propose").at(-1)).toMatchObject({ status: "error", output: expect.stringContaining("turned proposals off") });
	expect(xs.filter((i) => i.tool === "side_offer").at(-1)).toMatchObject({ status: "error", output: expect.stringContaining("turned these offers off") });
}, 90_000);

test("from a conversation with no project, a task about one of your projects goes there (SCQ5, 26 CL11)", async () => {
	const client = await start();
	const dir = repo();
	// Trusted, as your own projects are: Full access needs it (docs/spec/39).
	const { project: added } = (await client.call("projects.add", { path: dir })) as { project: { id: string } };
	await client.call("projects.configure", { id: added.id, trust: true });
	const name = dir.split("/").pop()!;
	const { ref: chat } = (await client.call("sessions.create", { kind: "thread" })) as { ref: Ref };
	await client.call("sessions.submit", { ref: chat, input: { text: `In that project, add a changelog, separately.\n${sideStart({ title: "Changelog", brief: "write: CHANGELOG.md | # Changes", project: name })}` } });
	const child = await until(() => sessions(client), (s) => s.some((x) => x.side?.state === "done")).then((s) => s.find((x) => x.side)!);
	expect(child).toMatchObject({ title: "Changelog", side: { parent: { id: chat.id }, how: "asked" }, worktree: { branch: expect.stringMatching(/^side\/changelog-/) } });
	expect(readFileSync(join(child.cwd!, "CHANGELOG.md"), "utf8")).toContain("# Changes");
	// The note came back to the chat.
	await until(() => items(client, chat), (x) => x.some((i) => i.kind === "user" && i.text?.startsWith("[Side] “Changelog”")));
	// An unknown project is refused.
	await idle(client, chat);
	await client.call("sessions.submit", { ref: chat, input: { text: `Separately, please.\n${sideStart({ title: "X", brief: "x", project: "Nowhere" })}` } });
	await until(() => items(client, chat), (x) => x.some((i) => i.tool === "side_start" && i.status === "error" && i.output?.includes("No project called “Nowhere”")));
}, 60_000);
