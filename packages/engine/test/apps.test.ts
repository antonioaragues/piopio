import { createHash } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { Apps, isAppFile, parseManifest, parseTable, type AppView } from "../src/apps.js";
import { kindOf } from "../src/library.js";
import { endDetails } from "../src/timeline/tool-details.js";

const PAGE = `<div id="out"></div><script>piopio.onData((data) => { document.getElementById("out").textContent = data.expenses.length; });</script>`;
const CSV = "date,category,amount\n2026-10-01,Food,120.5\n2026-10-03,Rent,800\n2026-11-02,Food,95\n";

let dirs: string[] = [];
function folder(): string {
	const d = mkdtempSync(join(tmpdir(), "apps-"));
	dirs.push(d);
	return d;
}
afterEach(() => {
	for (const d of dirs) rmSync(d, { recursive: true, force: true });
	dirs = [];
});

function setup(opts: { changed?: (v: AppView) => void } = {}) {
	const root = folder();
	const home = join(root, "home");
	const apps = new Apps({ home, appsDir: join(root, "Piopio", "Apps"), settleMs: 20, ...(opts.changed ? { changed: opts.changed } : {}) });
	return { root, home, apps };
}

/** A project with a CSV and an app made from it, as make_app would after Allow. */
function projectApp(opts: { changed?: (v: AppView) => void } = {}) {
	const s = setup(opts);
	const project = join(s.root, "household");
	mkdirSync(join(project, "data"), { recursive: true });
	writeFileSync(join(project, "data", "expenses.csv"), CSV);
	const plan = s.apps.plan({ title: "Spending", html: PAGE, sources: { expenses: { file: "data/expenses.csv", columns: ["date", "category", "amount"] } } }, { cwd: project });
	const view = s.apps.write(plan);
	return { ...s, project, plan, view, csv: join(project, "data", "expenses.csv") };
}

describe("tables (docs/spec/35 §14)", () => {
	it("reads quoted cells, a semicolon header and plain numbers", () => {
		expect(parseTable('name,note,amount\n"Doe, J.","says ""hi""",12.5\n').rows).toEqual([{ name: "Doe, J.", note: 'says "hi"', amount: 12.5 }]);
		const es = parseTable("fecha;categoría;importe\r\n2026-11-01;Comida;12,50\r\n");
		expect(es.columns).toEqual(["fecha", "categoría", "importe"]);
		// "12,50" isn't a plain number: it stays text for the page to read as it means.
		expect(es.rows).toEqual([{ fecha: "2026-11-01", categoría: "Comida", importe: "12,50" }]);
		expect(parseTable("a,b\n\n1,2\n").rows).toEqual([{ a: 1, b: 2 }]);
	});
});

describe("making an app", () => {
	it("in a project: under apps/, the manifest's path relative to the app, its sources allowed and read", () => {
		const { project, view, plan } = projectApp();
		expect(plan.path).toBe(join(project, "apps", "spending.html"));
		expect(plan.summary).toBe("Make the app “Spending” in apps/spending.html, reading data/expenses.csv");
		expect(parseManifest(readFileSync(plan.path, "utf8")).sources).toEqual({ expenses: { file: "../data/expenses.csv", columns: ["date", "category", "amount"] } });
		expect(view.allowed).toBe(true);
		expect(view.sources[0]).toMatchObject({ name: "expenses", state: "ok", path: join(project, "data", "expenses.csv") });
		expect(view.data.expenses).toHaveLength(3);
		expect(isAppFile(plan.path)).toBe(true);
		expect(kindOf(plan.path)).toBe("app");
		// Outside Piopio the page says where to open it.
		expect(readFileSync(plan.path, "utf8")).toContain("Open in Piopio to see live data");
	});

	it("doesn't overwrite an app with the same name", () => {
		const { apps, project } = projectApp();
		const again = apps.plan({ title: "Spending", html: PAGE, sources: { expenses: { file: "data/expenses.csv" } } }, { cwd: project });
		expect(again.path).toBe(join(project, "apps", "spending-2.html"));
	});

	it("refuses what would make a wrong or broken app, saying what to fix", () => {
		const { apps, project } = projectApp();
		const plan = (html: string, sources: Record<string, unknown>) => () => apps.plan({ title: "X", html, sources: sources as never }, { cwd: project });
		expect(plan("<p>Total: 1.015 €</p>", { expenses: { file: "data/expenses.csv" } })).toThrow(/piopio\.onData/);
		expect(plan(PAGE, { expenses: { file: "data/nope.csv" } })).toThrow(/isn't there/);
		expect(plan(PAGE, { expenses: { file: "data/expenses.csv", columns: ["importe"] } })).toThrow(/no “importe” column/);
		expect(plan(PAGE, { week: { tool: "calendar_events" } })).toThrow(/isn't a file/);
		expect(plan(PAGE, {})).toThrow(/no sources/);
	});

	it("from a chat: its source is copied beside the app, which still opens after the chat's folder is gone", () => {
		const { apps, root } = setup();
		const chat = join(root, "home", "scratch", "c1");
		mkdirSync(chat, { recursive: true });
		writeFileSync(join(chat, "expenses.csv"), CSV);
		const plan = apps.plan({ title: "Gastos del mes", html: PAGE, sources: { expenses: { file: "expenses.csv" } } }, { cwd: chat, chatFolder: chat });
		expect(plan.path).toBe(join(root, "Piopio", "Apps", "gastos-del-mes", "gastos-del-mes.html"));
		expect(plan.summary).toBe("Make the app “Gastos del mes” in Piopio/Apps/gastos-del-mes/gastos-del-mes.html, reading a copy of expenses.csv kept beside it");
		apps.write(plan);
		rmSync(chat, { recursive: true, force: true });
		const view = apps.openApp(plan.path);
		expect(view.sources[0]).toMatchObject({ file: "expenses.csv", state: "ok" });
		expect(view.data.expenses).toHaveLength(3);
		apps.closeApp(plan.path);
	});

	it("keeps an absolute path (a synced Drive folder) as it is", () => {
		const { apps, root } = setup();
		const drive = join(root, "CloudStorage", "GoogleDrive", "budget.json");
		mkdirSync(join(root, "CloudStorage", "GoogleDrive"), { recursive: true });
		writeFileSync(drive, JSON.stringify({ month: 1100 }));
		const project = join(root, "p");
		mkdirSync(project);
		const plan = apps.plan({ title: "Budget", html: PAGE, sources: { budget: { file: drive } } }, { cwd: project });
		expect(plan.manifest.sources.budget!.file).toBe(drive);
		expect(apps.write(plan).data.budget).toEqual({ month: 1100 });
	});
});

describe("when the data changes or goes wrong", () => {
	it("a row in a new category reaches the page as data, with no model", () => {
		const { apps, plan, csv } = projectApp();
		appendFileSync(csv, "2026-11-20,Car,450\n");
		const view = apps.refresh(plan.path);
		const rows = view.data.expenses as { category: string; amount: number }[];
		expect(rows).toHaveLength(4);
		expect(new Set(rows.map((r) => r.category))).toEqual(new Set(["Food", "Rent", "Car"]));
		expect(rows.filter((r) => r.category !== "Rent").reduce((n, r) => n + r.amount, 0)).toBe(665.5);
		expect(view.stale).toEqual([]);
	});

	it("an empty file fails: the last good data stays, dated", () => {
		const { apps, plan, csv, view: first } = projectApp();
		writeFileSync(csv, "");
		const view = apps.refresh(plan.path);
		expect(view.sources[0]).toMatchObject({ state: "failed", error: "expenses.csv is empty.", readAt: first.sources[0]!.readAt });
		expect(view.sources[0]!.failedAt).toBeDefined();
		expect(view.data.expenses).toHaveLength(3);
		expect(view.stale).toEqual(["expenses"]);
		// Fixed: back to ok.
		writeFileSync(csv, CSV);
		expect(apps.refresh(plan.path).sources[0]).toMatchObject({ state: "ok" });
	});

	it("a renamed column fails with what the file has now, instead of drawing zeros", () => {
		const { apps, plan, csv } = projectApp();
		writeFileSync(csv, "date,category,importe\n2026-11-02,Food,95\n");
		const view = apps.refresh(plan.path);
		expect(view.sources[0]!.error).toBe("expenses.csv has no “amount” column (it has “date”, “category”, “importe”).");
		expect(view.data.expenses).toHaveLength(3);
	});

	it("a gone file fails the same way", () => {
		const { apps, plan, csv } = projectApp();
		rmSync(csv);
		expect(apps.refresh(plan.path).sources[0]).toMatchObject({ state: "failed", error: "expenses.csv isn't there any more." });
	});

	it("an open app hears its file change", async () => {
		const seen: AppView[] = [];
		const { apps, plan, csv } = projectApp({ changed: (v) => seen.push(v) });
		apps.openApp(plan.path);
		appendFileSync(csv, "2026-11-21,Car,450\n");
		for (let i = 0; i < 100 && !seen.length; i++) await new Promise((r) => setTimeout(r, 20));
		expect((seen.at(-1)!.data.expenses as unknown[]).length).toBe(4);
		apps.closeApp(plan.path);
		apps.stop();
	});
});

describe("allowing sources (docs/spec/35 §3.4)", () => {
	it("a page edit asks nothing; a new source waits for Allow, drawing what was read before", () => {
		const { apps, plan, project } = projectApp();
		const html = readFileSync(plan.path, "utf8");
		writeFileSync(plan.path, html.replace("textContent", "innerText"));
		expect(apps.refresh(plan.path).allowed).toBe(true);
		writeFileSync(join(project, "data", "budget.json"), JSON.stringify({ month: 1100 }));
		writeFileSync(plan.path, html.replace('"columns"', '"x": 1, "columns"').replace(/"sources": \{/, '"sources": {\n\t\t"budget": { "file": "../data/budget.json" },'));
		const waiting = apps.refresh(plan.path);
		expect(waiting.allowed).toBe(false);
		expect(waiting.sources.map((s) => s.state)).toEqual(["waiting", "waiting"]);
		expect(waiting.data.expenses).toHaveLength(3);
		expect(waiting.data.budget).toBeUndefined();
		const allowed = apps.allow(plan.path);
		expect(allowed.allowed).toBe(true);
		expect(allowed.data.budget).toEqual({ month: 1100 });
	});

	it("what's allowed survives a restart", () => {
		const { home, root, plan } = projectApp();
		const again = new Apps({ home, appsDir: join(root, "Piopio", "Apps") });
		expect(again.refresh(plan.path).allowed).toBe(true);
	});
});

describe("in the transcript and the Library", () => {
	it("make_app's result is a file card with the app", () => {
		const details = endDetails("make_app", {}, { details: { files: [{ path: "/p/apps/spending.html", name: "spending.html", description: "App: Spending" }] } }, "Made", false);
		expect(details).toEqual({ type: "files", files: [{ path: "/p/apps/spending.html", name: "spending.html", description: "App: Spending" }] });
		expect(existsSync("/p/apps/spending.html")).toBe(false);
	});
});

describe("the app's conversation and Undo (docs/spec/35 §15)", () => {
	it("one request's edits are one change; Undo puts the page back and keeps the new data", () => {
		const { apps, plan, csv } = projectApp();
		const original = readFileSync(plan.path, "utf8");
		apps.noteRequest(plan.path, "Add a budget line at 1.100 €\nand more");
		writeFileSync(plan.path, original.replace('<div id="out"></div>', '<div id="out"></div><hr>'));
		apps.refresh(plan.path);
		writeFileSync(plan.path, original.replace('<div id="out"></div>', '<div id="out"></div><hr class="budget">'));
		appendFileSync(csv, "2026-11-20,Car,450\n");
		const changed = apps.refresh(plan.path);
		expect(changed.undo).toMatchObject({ label: "Add a budget line at 1.100 €" });
		const back = apps.undo(plan.path);
		expect(readFileSync(plan.path, "utf8")).toBe(original);
		expect(back.data.expenses).toHaveLength(4);
		expect(back.undo).toBeUndefined();
		expect(() => apps.undo(plan.path)).toThrow(/nothing to undo/);
	});

	it("Undo goes back one request at a time", () => {
		const { apps, plan } = projectApp();
		const v0 = readFileSync(plan.path, "utf8");
		apps.noteRequest(plan.path, "First");
		writeFileSync(plan.path, `${v0}<p>1</p>`);
		apps.refresh(plan.path);
		apps.noteRequest(plan.path, "Second");
		writeFileSync(plan.path, `${v0}<p>1</p><p>2</p>`);
		expect(apps.refresh(plan.path).undo?.label).toBe("Second");
		expect(apps.undo(plan.path).undo?.label).toBe("First");
		apps.undo(plan.path);
		expect(readFileSync(plan.path, "utf8")).toBe(v0);
	});

	it("an edit made outside Piopio isn't Undo's, and Undo won't overwrite it without asking", () => {
		const { apps, plan } = projectApp();
		const v0 = readFileSync(plan.path, "utf8");
		writeFileSync(plan.path, `${v0}<!-- mine -->`);
		expect(apps.refresh(plan.path).undo).toBeUndefined();
		apps.noteRequest(plan.path, "Green bars");
		writeFileSync(plan.path, `${v0}<!-- mine --><p>green</p>`);
		apps.refresh(plan.path);
		const forgotten = new Apps({ home: join(dirname(plan.path), "..", "..", "home"), appsDir: "/nowhere" });
		writeFileSync(plan.path, `${v0}<!-- mine --><p>green</p><!-- later, in my editor -->`);
		expect(() => forgotten.undo(plan.path)).toThrow(/changed outside Piopio after “Green bars”/);
		forgotten.undo(plan.path, true);
		expect(readFileSync(plan.path, "utf8")).toBe(`${v0}<!-- mine -->`);
	});

	it("tells its conversation where the app is, what it reads, and to answer questions without changing it", () => {
		const { apps, plan, csv } = projectApp();
		const text = apps.describe(plan.path);
		expect(text).toContain(`The app “Spending” is the page ${plan.path}`);
		expect(text).toContain(`- expenses: ${csv} (columns date, category, amount)`);
		expect(text).toContain("answer it here, and don't change the app");
		expect(text).toContain("don't read the data for it");
	});
});

describe("what an app may read (audit M1)", () => {
	it("never keys or credentials, even through a symlink in the project", () => {
		const { root, apps } = setup();
		const realHome = process.env.HOME;
		const home = join(root, "user");
		mkdirSync(join(home, ".aws"), { recursive: true });
		writeFileSync(join(home, ".aws", "keys.json"), '{"key":"secret"}');
		const project = join(root, "proj");
		mkdirSync(project);
		symlinkSync(join(home, ".aws", "keys.json"), join(project, "data.json"));
		process.env.HOME = home;
		try {
			for (const file of [join(home, ".aws", "keys.json"), "data.json"]) {
				expect(() => apps.plan({ title: "Keys", html: PAGE, sources: { k: { file } } }, { cwd: project })).toThrow(/key or credentials file \(in ~\/\.aws\)/);
			}
		} finally {
			process.env.HOME = realHome;
		}
	});

	it("an app allowed with the old short hash stays allowed, and keeps the full one from then on", () => {
		const { home, apps, plan } = projectApp();
		const state = JSON.parse(readFileSync(join(home, "apps.json"), "utf8")) as { allowed: Record<string, string> };
		expect(state.allowed[plan.path]).toMatch(/^[0-9a-f]{64}$/);
		const sorted = JSON.stringify(Object.keys(plan.manifest.sources).sort().map((k) => [k, plan.manifest.sources[k]!.file, plan.manifest.sources[k]!.columns ?? []]));
		state.allowed[plan.path] = createHash("sha1").update(sorted).digest("hex").slice(0, 16);
		writeFileSync(join(home, "apps.json"), JSON.stringify(state));
		const again = new Apps({ home, appsDir: join(dirname(home), "Piopio", "Apps") });
		expect(again.refresh(plan.path).allowed).toBe(true);
		expect((JSON.parse(readFileSync(join(home, "apps.json"), "utf8")) as typeof state).allowed[plan.path]).toMatch(/^[0-9a-f]{64}$/);
		apps.closeApp(plan.path);
	});
});
