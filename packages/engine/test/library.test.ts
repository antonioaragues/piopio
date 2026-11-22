import { mkdirSync, mkdtempSync, readdirSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { TimelineItem } from "@piopio/protocol";
import { kindOf, Library, LibrarySearch, type LibraryOrigin, noteRequest } from "../src/library.js";

let dir: string;
beforeEach(() => {
	dir = mkdtempSync(join(tmpdir(), "piopio-library-"));
});
afterEach(() => rmSync(dir, { recursive: true, force: true }));

let n = 0;
const at = (minute: number) => new Date(Date.UTC(2026, 10, 22, 10, minute)).toISOString();
const user = (minute: number, text = "hi"): TimelineItem => ({ kind: "user", id: `u${++n}`, at: at(minute), text }) as TimelineItem;
const tool = (minute: number, name: string, args: unknown, details?: unknown, status = "done"): TimelineItem =>
	({ kind: "tool", id: `t${++n}`, at: at(minute), callId: `c${n}`, tool: name, args, status, ...(details ? { details } : {}) }) as TimelineItem;
const presented = (minute: number, ...files: { path: string; name: string; description?: string; missing?: boolean }[]) => tool(minute, "present_files", { files: files.map((f) => ({ path: f.path })) }, { type: "files", files });
const visual = (minute: number, title: string, status = "done") => tool(minute, "show_visual", { title, html: "<div></div>" }, undefined, status);

function file(name: string, text = "x"): string {
	const path = join(dir, name);
	mkdirSync(join(path, ".."), { recursive: true });
	writeFileSync(path, text);
	return path;
}

const chat: LibraryOrigin = { ref: { kind: "thread", id: "t1" }, title: "Gas contract", by: "Piopio" };
const rita: LibraryOrigin = { ref: { kind: "agent", id: "a1" }, title: "Rita", by: "Rita" };

describe("Library (docs/spec/35 §4)", () => {
	it("lists files handed over with present_files, with their note, origin and who made it", () => {
		const lib = new Library(join(dir, "library.json"));
		const csv = file("gas.csv", "a,b\n1,2\n");
		lib.observe(chat, [user(0), presented(1, { path: csv, name: "gas.csv", description: "Gas offers compared" })]);
		const [item] = lib.list().items;
		expect(item).toMatchObject({ kind: "data", name: "gas.csv", path: csv, note: "Gas offers compared", by: "Piopio", how: "presented", origin: { ref: chat.ref, title: "Gas contract" }, size: 8 });
		expect(item!.missing).toBeUndefined();
	});

	it("keeps where a file first came from when another conversation hands it over again", () => {
		const lib = new Library(join(dir, "library.json"));
		const pdf = file("car.pdf");
		lib.observe(rita, [presented(1, { path: pdf, name: "car.pdf" })]);
		lib.observe(chat, [presented(5, { path: pdf, name: "car.pdf", description: "Car insurance, compared" })]);
		const items = lib.list().items;
		expect(items).toHaveLength(1);
		expect(items[0]).toMatchObject({ by: "Rita", origin: { title: "Rita" }, note: "Car insurance, compared" });
	});

	it("follows a conversation's new title", () => {
		const lib = new Library(join(dir, "library.json"));
		const md = file("plan.md");
		const items = [user(0), presented(1, { path: md, name: "plan.md" }), visual(2, "Chart")];
		lib.observe({ ...chat, title: "Make me a plan for…" }, items);
		lib.observe({ ...chat, title: "Lisbon plan" }, items);
		expect(lib.list().items.map((i) => i.origin?.title)).toEqual(["Lisbon plan", "Lisbon plan"]);
	});

	it("writes a note for a new text file that came without one, not for history or other files", async () => {
		const lib = new Library(join(dir, "library.json"));
		const asked: string[] = [];
		lib.describe = async (f, origin) => {
			asked.push(`${f.name} · ${origin.title} · ${f.text.slice(0, 9)}`);
			return '"Gas offers from three companies, compared."\nmore';
		};
		const old = file("old.md", "# Old");
		lib.observe(chat, [presented(1, { path: old, name: "old.md" })]);
		const csv = file("gas.csv", "company,price\nIberdrola,0.12\n");
		const png = file("chart.png", "x");
		const noted = file("noted.md", "# N");
		lib.observeItem(chat, presented(2, { path: csv, name: "gas.csv" }));
		lib.observeItem(chat, presented(3, { path: png, name: "chart.png" }));
		lib.observeItem(chat, presented(4, { path: noted, name: "noted.md", description: "Already said" }));
		await lib.notesDone();
		expect(asked).toEqual(["gas.csv · Gas contract · company,p"]);
		const notes = Object.fromEntries(lib.list().items.map((i) => [i.name, i.note]));
		expect(notes).toEqual({ "gas.csv": "Gas offers from three companies, compared", "chart.png": undefined, "noted.md": "Already said", "old.md": undefined });
	});

	it("skips files present_files couldn't find", () => {
		const lib = new Library(join(dir, "library.json"));
		lib.observe(chat, [presented(1, { path: join(dir, "nope.md"), name: "nope.md", missing: true })]);
		expect(lib.list().items).toEqual([]);
	});

	it("takes what a chat writes in its own folder when it's meant to be looked at, not code or hidden files", () => {
		const lib = new Library(join(dir, "library.json"));
		const folder = join(dir, "scratch", "t1");
		file("scratch/t1/plan.md");
		const origin = { ...chat, chatFolder: folder };
		lib.observe(origin, [
			tool(1, "write", { path: "plan.md", content: "# Plan" }),
			tool(2, "write", { path: "script.py", content: "print(1)" }),
			tool(3, "write", { path: ".notes.md", content: "x" }),
			tool(4, "write", { path: join(dir, "elsewhere.md"), content: "x" }),
		]);
		expect(lib.list().items.map((i) => [i.name, i.how])).toEqual([["plan.md", "written"]]);
		// Without a chat folder (a project's conversation), writes don't come in.
		const other = new Library(join(dir, "other.json"));
		other.observe(chat, [tool(1, "write", { path: join(folder, "plan.md"), content: "# Plan" })]);
		expect(other.list().items).toEqual([]);
	});

	it("lists visuals, without the drafts a fix replaced in the same turn", () => {
		const lib = new Library(join(dir, "library.json"));
		lib.observe(chat, [user(0), visual(1, "Spending"), visual(2, "spending "), visual(3, "Other"), user(4), visual(5, "Spending")]);
		const items = lib.list().items;
		expect(items.map((i) => [i.name, i.at])).toEqual([
			["Spending", at(5)],
			["Other", at(3)],
			["spending", at(2)],
		]);
		expect(items.every((i) => i.kind === "visual" && i.visual && !i.path)).toBe(true);
	});

	it("replaces a draft as items arrive one at a time, within the turn only", () => {
		const lib = new Library(join(dir, "library.json"));
		lib.observeItem(chat, user(0));
		lib.observeItem(chat, visual(1, "Chart"));
		lib.observeItem(chat, visual(2, "Chart", "running"));
		lib.observeItem(chat, visual(3, "Chart"));
		expect(lib.list().items.map((i) => i.at)).toEqual([at(3)]);
		lib.observeItem(chat, user(4));
		lib.observeItem(chat, visual(5, "Chart"));
		expect(lib.list().items.map((i) => i.at)).toEqual([at(5), at(3)]);
	});

	it("keeps each visual's HTML to draw it, and drops it with the visual", () => {
		const lib = new Library(join(dir, "library.json"));
		const draft = tool(1, "show_visual", { title: "Chart", html: "<p>draft</p>" });
		const fixed = tool(2, "show_visual", { title: "Chart", html: "<p>fixed</p>" });
		lib.observe(chat, [user(0), draft, fixed]);
		const [only] = lib.list().items;
		expect(lib.visual(only!.id)).toEqual({ title: "Chart", html: "<p>fixed</p>" });
		expect(readdirSync(join(dir, "library-visuals"))).toEqual([`${only!.id}.html`]);
		lib.forget("t1");
		expect(readdirSync(join(dir, "library-visuals"))).toEqual([]);
		expect(() => lib.visual(only!.id)).toThrow("isn't in the Library");
	});

	it("re-reading a conversation drops visuals it no longer shows (a branch switched, a turn undone)", () => {
		const lib = new Library(join(dir, "library.json"));
		lib.observe(chat, [user(0), visual(1, "A"), visual(2, "B")]);
		lib.observe(chat, [user(0), visual(1, "A")]);
		expect(lib.list().items.map((i) => i.name)).toEqual(["A"]);
	});

	it("pins first, reorders, and keeps pins and removals across restarts", () => {
		const path = join(dir, "library.json");
		const lib = new Library(path);
		const a = file("a.md");
		const b = file("b.md");
		lib.observe(chat, [presented(1, { path: a, name: "a.md" }), presented(2, { path: b, name: "b.md" })]);
		const ids = Object.fromEntries(lib.list().items.map((i) => [i.name, i.id]));
		lib.pin(ids["a.md"]!, true);
		lib.pin(ids["b.md"]!, true);
		expect(lib.list().pins).toEqual([ids["b.md"], ids["a.md"]]);
		lib.reorder([ids["a.md"]!]);
		expect(lib.list().pins).toEqual([ids["a.md"], ids["b.md"]]);
		lib.remove(ids["b.md"]!);
		const again = new Library(path);
		again.observe(chat, [presented(2, { path: b, name: "b.md" })]);
		expect(again.list()).toMatchObject({ pins: [ids["a.md"]], items: [{ name: "a.md", pinned: true }] });
		// Adding it by hand brings it back.
		expect(again.add(b).name).toBe("b.md");
		expect(again.list().items.map((i) => i.name)).toContain("b.md");
		expect(() => again.pin("nope", true)).toThrow("isn't in the Library");
	});

	it("marks a moved file missing, and Locate… finds it again with its pin", () => {
		const lib = new Library(join(dir, "library.json"));
		const a = file("report.md");
		lib.observe(chat, [presented(1, { path: a, name: "report.md" })]);
		const id = lib.list().items[0]!.id;
		lib.pin(id, true);
		const moved = join(dir, "moved.md");
		renameSync(a, moved);
		expect(lib.list().items[0]).toMatchObject({ missing: true });
		const found = lib.relocate(id, moved);
		expect(found).toMatchObject({ path: moved, name: "moved.md", pinned: true });
		expect(found.missing).toBeUndefined();
		expect(lib.list().pins).toEqual([found.id]);
	});

	it("lets a missing file go after 30 days, and forgives one that comes back", () => {
		const lib = new Library(join(dir, "library.json"));
		const a = file("a.md");
		const b = file("b.md");
		lib.observe(chat, [presented(1, { path: a, name: "a.md" }), presented(2, { path: b, name: "b.md" })]);
		const ids = Object.fromEntries(lib.list().items.map((i) => [i.name, i.id]));
		lib.pin(ids["a.md"]!, true);
		const day = 86_400_000;
		const t0 = Date.now();
		rmSync(a);
		rmSync(b);
		expect(lib.list(t0).items.every((i) => i.missing)).toBe(true);
		writeFileSync(b, "back");
		expect(lib.list(t0 + 10 * day).items.map((i) => [i.name, i.missing ?? false])).toEqual([["b.md", false], ["a.md", true]]);
		rmSync(b);
		lib.list(t0 + 20 * day);
		expect(lib.list(t0 + 31 * day)).toEqual({ items: [expect.objectContaining({ name: "b.md", missing: true })], pins: [], removed: [] });
		expect(lib.list(t0 + 51 * day).items).toEqual([]);
	});

	it("keeps one entry after Locate…, when the conversation is read again and after a restart", () => {
		const path = join(dir, "library.json");
		const lib = new Library(path);
		const original = file("original.csv");
		const handover = [presented(1, { path: original, name: "original.csv" })];
		lib.observe(chat, handover);
		const id = lib.list().items[0]!.id;
		lib.pin(id, true);
		const moved = join(dir, "presupuesto.csv");
		renameSync(original, moved);
		const found = lib.relocate(id, moved);
		lib.observe(chat, handover);
		const again = new Library(path);
		again.observe(chat, handover);
		for (const l of [lib, again]) expect(l.list()).toMatchObject({ items: [{ id: found.id, path: moved, pinned: true }], pins: [found.id] });
		expect(again.list().items).toHaveLength(1);
	});

	it("takes a visual's new HTML even when it's the same size, with a new version", () => {
		const lib = new Library(join(dir, "library.json"));
		lib.observe(chat, [user(0), { ...visual(1, "N"), callId: "same", args: { title: "N", html: "<p>120</p>" } } as TimelineItem]);
		const before = lib.list().items[0]!;
		lib.observe(chat, [user(0), { ...visual(1, "N"), callId: "same", args: { title: "N", html: "<p>999</p>" } } as TimelineItem]);
		const after = lib.list().items[0]!;
		expect(lib.visual(after.id).html).toBe("<p>999</p>");
		expect(after.visual?.version).not.toBe(before.visual?.version);
	});

	it("leaves out what a chat writes in hidden folders", () => {
		const lib = new Library(join(dir, "library.json"));
		const folder = join(dir, "scratch", "t1");
		lib.observe({ ...chat, chatFolder: folder }, [tool(1, "write", { path: ".cache/metadata.json", content: "{}" }), tool(2, "write", { path: "out/.tmp/x.md", content: "x" }), tool(3, "write", { path: "notes/plan.md", content: "x" })]);
		expect(lib.list().items.map((i) => i.name)).toEqual(["plan.md"]);
	});

	it("asks for a note the way the maker would: an agent's utility off means no call", () => {
		expect(noteRequest({ default: "openrouter:anthropic/claude-sonnet-5.5", utility: "off" })).toBeNull();
		expect(noteRequest({ default: "openrouter:anthropic/claude-sonnet-5.5", utility: "on-device" })).toEqual({ model: { provider: "openrouter", id: "anthropic/claude-sonnet-5.5" }, choice: "on_device" });
		expect(noteRequest({ default: "openrouter:x/y" })).toEqual({ model: { provider: "openrouter", id: "x/y" } });
		expect(noteRequest(undefined, { provider: "openrouter", id: "a/b" })).toEqual({ model: { provider: "openrouter", id: "a/b" } });
	});

	it("puts back what you removed, and lists it as removed meanwhile", () => {
		const lib = new Library(join(dir, "library.json"));
		lib.observe(chat, [user(0), visual(1, "Chart")]);
		const id = lib.list().items[0]!.id;
		lib.remove(id);
		expect(lib.list()).toMatchObject({ items: [], removed: [{ id, name: "Chart" }] });
		lib.restore(id);
		expect(lib.list()).toMatchObject({ items: [{ id }], removed: [] });
	});

	it("links a saved visual to its file: one item, its pin kept, a later handover of the file finds it", () => {
		const lib = new Library(join(dir, "library.json"));
		lib.observe(chat, [user(0), { ...visual(1, "Chart"), callId: "cv" } as TimelineItem]);
		const id = lib.list().items[0]!.id;
		lib.pin(id, true);
		const saved = file("Chart.html", "<html></html>");
		expect(lib.saved("cv", saved)).toMatchObject({ id, kind: "visual", path: saved, pinned: true });
		lib.observe(chat, [user(0), { ...visual(1, "Chart"), callId: "cv" } as TimelineItem, presented(3, { path: saved, name: "Chart.html" })]);
		expect(lib.list()).toMatchObject({ items: [{ id, path: saved }], pins: [id] });
		rmSync(saved);
		expect(lib.list().items[0]).toMatchObject({ id, kind: "visual" });
		expect(lib.list().items[0]!.path).toBeUndefined();
		expect(lib.list(Date.now() + 40 * 86_400_000).items).toHaveLength(1);
	});

	it("forgets a deleted conversation's visuals and keeps its files", () => {
		const lib = new Library(join(dir, "library.json"));
		const a = file("a.md");
		lib.observe(chat, [visual(1, "V"), presented(2, { path: a, name: "a.md" })]);
		lib.forget("t1");
		expect(lib.list().items.map((i) => i.name)).toEqual(["a.md"]);
	});

	it("tells what a file is by its extension", () => {
		expect(["x.md", "x.PDF", "x.html", "x.png", "x.csv", "x.xlsx", "x.key", "x.swift"].map(kindOf)).toEqual(["document", "document", "page", "image", "data", "data", "slides", "file"]);
	});

	it("fills from what search reads", () => {
		const lib = new Library(join(dir, "library.json"));
		const origins: Record<string, LibraryOrigin> = { t1: chat, "a1/person:c1": { ...rita, ref: { ...rita.ref, conversationId: "person:c1" } } };
		const search = new LibrarySearch(join(dir, "search.db"), {
			replaced: (key, items) => lib.observe(origins[key]!, items),
			item: (key, item) => lib.observeItem(origins[key]!, item),
			deleted: (id) => lib.forget(id),
		});
		search.replaceSession("t1", "Gas", at(0), [user(0), visual(1, "Prices")]);
		search.upsertItem("a1/person:c1", visual(2, "Rita's chart"));
		expect(lib.list().items.map((i) => [i.name, i.by])).toEqual([["Rita's chart", "Rita"], ["Prices", "Piopio"]]);
		search.close();
	});
});
