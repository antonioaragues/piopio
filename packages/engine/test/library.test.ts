import { mkdirSync, mkdtempSync, renameSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, beforeEach, describe, expect, it } from "vitest";
import type { TimelineItem } from "@piopio/protocol";
import { kindOf, Library, LibrarySearch, type LibraryOrigin } from "../src/library.js";

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
