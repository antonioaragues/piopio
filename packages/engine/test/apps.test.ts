import { createHash } from "node:crypto";
import { appendFileSync, existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { dirname, join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { calendarSpan, isAppFile, parseManifest } from "../src/app-manifest.js";
import { parseTable } from "../src/app-sources.js";
import { Apps, type AppView } from "../src/apps.js";
import { kindOf } from "../src/library.js";
import { endDetails } from "@piopio/runtime";

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
async function projectApp(opts: { changed?: (v: AppView) => void } = {}) {
	const s = setup(opts);
	const project = join(s.root, "household");
	mkdirSync(join(project, "data"), { recursive: true });
	writeFileSync(join(project, "data", "expenses.csv"), CSV);
	const plan = s.apps.plan({ title: "Spending", html: PAGE, sources: { expenses: { file: "data/expenses.csv", columns: ["date", "category", "amount"] } } }, { cwd: project });
	const view = await s.apps.write(plan);
	return { ...s, project, plan, view, csv: join(project, "data", "expenses.csv") };
}

describe("tables (docs/spec/35 §14)", () => {
	it("reads quoted cells, a semicolon header and plain numbers", async () => {
		expect(parseTable('name,note,amount\n"Doe, J.","says ""hi""",12.5\n').rows).toEqual([{ name: "Doe, J.", note: 'says "hi"', amount: 12.5 }]);
		const es = parseTable("fecha;categoría;importe\r\n2026-11-01;Comida;12,50\r\n");
		expect(es.columns).toEqual(["fecha", "categoría", "importe"]);
		// "12,50" isn't a plain number: it stays text for the page to read as it means.
		expect(es.rows).toEqual([{ fecha: "2026-11-01", categoría: "Comida", importe: "12,50" }]);
		expect(parseTable("a,b\n\n1,2\n").rows).toEqual([{ a: 1, b: 2 }]);
	});
});

describe("making an app", () => {
	it("in a project: under apps/, the manifest's path relative to the app, its sources allowed and read", async () => {
		const { project, view, plan } = await projectApp();
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

	it("doesn't overwrite an app with the same name", async () => {
		const { apps, project } = await projectApp();
		const again = apps.plan({ title: "Spending", html: PAGE, sources: { expenses: { file: "data/expenses.csv" } } }, { cwd: project });
		expect(again.path).toBe(join(project, "apps", "spending-2.html"));
	});

	it("refuses what would make a wrong or broken app, saying what to fix", async () => {
		const { apps, project } = await projectApp();
		const plan = (html: string, sources: Record<string, unknown>) => () => apps.plan({ title: "X", html, sources: sources as never }, { cwd: project });
		expect(plan("<p>Total: 1.015 €</p>", { expenses: { file: "data/expenses.csv" } })).toThrow(/piopio\.onData/);
		expect(plan(PAGE, { expenses: { file: "data/nope.csv" } })).toThrow(/isn't there/);
		expect(plan(PAGE, { expenses: { file: "data/expenses.csv", columns: ["importe"] } })).toThrow(/no “importe” column/);
		expect(plan(PAGE, { week: { tool: "calendar_events" } })).toThrow(/isn't a file/);
		expect(plan(PAGE, {})).toThrow(/no sources/);
	});

	it("from a chat: its source is copied beside the app, which still opens after the chat's folder is gone", async () => {
		const { apps, root } = setup();
		const chat = join(root, "home", "scratch", "c1");
		mkdirSync(chat, { recursive: true });
		writeFileSync(join(chat, "expenses.csv"), CSV);
		const plan = apps.plan({ title: "Gastos del mes", html: PAGE, sources: { expenses: { file: "expenses.csv" } } }, { cwd: chat, chatFolder: chat });
		expect(plan.path).toBe(join(root, "Piopio", "Apps", "gastos-del-mes", "gastos-del-mes.html"));
		expect(plan.summary).toBe("Make the app “Gastos del mes” in Piopio/Apps/gastos-del-mes/gastos-del-mes.html, reading a copy of expenses.csv kept beside it");
		await apps.write(plan);
		rmSync(chat, { recursive: true, force: true });
		const view = apps.openApp(plan.path);
		expect(view.sources[0]).toMatchObject({ file: "expenses.csv", state: "ok" });
		expect(view.data.expenses).toHaveLength(3);
		apps.closeApp(plan.path);
	});

	it("keeps an absolute path (a synced Drive folder) as it is", async () => {
		const { apps, root } = setup();
		const drive = join(root, "CloudStorage", "GoogleDrive", "budget.json");
		mkdirSync(join(root, "CloudStorage", "GoogleDrive"), { recursive: true });
		writeFileSync(drive, JSON.stringify({ month: 1100 }));
		const project = join(root, "p");
		mkdirSync(project);
		const plan = apps.plan({ title: "Budget", html: PAGE, sources: { budget: { file: drive } } }, { cwd: project });
		expect(plan.manifest.sources.budget!.file).toBe(drive);
		expect((await apps.write(plan)).data.budget).toEqual({ month: 1100 });
	});
});

describe("when the data changes or goes wrong", () => {
	it("a row in a new category reaches the page as data, with no model", async () => {
		const { apps, plan, csv } = await projectApp();
		appendFileSync(csv, "2026-11-20,Car,450\n");
		const view = await apps.refresh(plan.path);
		const rows = view.data.expenses as { category: string; amount: number }[];
		expect(rows).toHaveLength(4);
		expect(new Set(rows.map((r) => r.category))).toEqual(new Set(["Food", "Rent", "Car"]));
		expect(rows.filter((r) => r.category !== "Rent").reduce((n, r) => n + r.amount, 0)).toBe(665.5);
		expect(view.stale).toEqual([]);
	});

	it("an empty file fails: the last good data stays, dated", async () => {
		const { apps, plan, csv, view: first } = await projectApp();
		writeFileSync(csv, "");
		const view = await apps.refresh(plan.path);
		expect(view.sources[0]).toMatchObject({ state: "failed", error: "expenses.csv is empty.", readAt: first.sources[0]!.readAt });
		expect(view.sources[0]!.failedAt).toBeDefined();
		expect(view.data.expenses).toHaveLength(3);
		expect(view.stale).toEqual(["expenses"]);
		// Fixed: back to ok.
		writeFileSync(csv, CSV);
		expect((await apps.refresh(plan.path)).sources[0]).toMatchObject({ state: "ok" });
	});

	it("a renamed column fails with what the file has now, instead of drawing zeros", async () => {
		const { apps, plan, csv } = await projectApp();
		writeFileSync(csv, "date,category,importe\n2026-11-02,Food,95\n");
		const view = await apps.refresh(plan.path);
		expect(view.sources[0]!.error).toBe("expenses.csv has no “amount” column (it has “date”, “category”, “importe”).");
		expect(view.data.expenses).toHaveLength(3);
	});

	it("a gone file fails the same way", async () => {
		const { apps, plan, csv } = await projectApp();
		rmSync(csv);
		expect((await apps.refresh(plan.path)).sources[0]).toMatchObject({ state: "failed", error: "expenses.csv isn't there any more." });
	});

	it("an open app hears its file change", async () => {
		const seen: AppView[] = [];
		const { apps, plan, csv } = await projectApp({ changed: (v) => seen.push(v) });
		apps.openApp(plan.path);
		// A folder watch on macOS can miss a change made the instant it starts; a person saves later than that.
		await new Promise((r) => setTimeout(r, 150));
		appendFileSync(csv, "2026-11-21,Car,450\n");
		for (let i = 0; i < 100 && !seen.length; i++) await new Promise((r) => setTimeout(r, 20));
		expect((seen.at(-1)!.data.expenses as unknown[]).length).toBe(4);
		apps.closeApp(plan.path);
		apps.stop();
	});
});

describe("allowing sources (docs/spec/35 §3.4)", () => {
	// Re-audit 2026-11-25 V7: Stop reading forgot only calendars; a file's rows kept showing.
	it("Stop reading forgets a file's rows too, until it's allowed and read again", async () => {
		const { apps, plan } = await projectApp();
		expect(Object.keys(apps.openApp(plan.path).data)).toEqual(["expenses"]);
		const stopped = apps.revoke(plan.path);
		expect(stopped.data).toEqual({});
		expect(apps.openApp(plan.path).data).toEqual({});
		expect(Object.keys((await apps.allow(plan.path)).data)).toEqual(["expenses"]);
		apps.closeApp(plan.path);
	});

	it("a page edit asks nothing; a new source waits for Allow, drawing what was read before", async () => {
		const { apps, plan, project } = await projectApp();
		const html = readFileSync(plan.path, "utf8");
		writeFileSync(plan.path, html.replace("textContent", "innerText"));
		expect((await apps.refresh(plan.path)).allowed).toBe(true);
		writeFileSync(join(project, "data", "budget.json"), JSON.stringify({ month: 1100 }));
		writeFileSync(plan.path, html.replace('"columns"', '"x": 1, "columns"').replace(/"sources": \{/, '"sources": {\n\t\t"budget": { "file": "../data/budget.json" },'));
		const waiting = await apps.refresh(plan.path);
		expect(waiting.allowed).toBe(false);
		expect(waiting.sources.map((s) => s.state)).toEqual(["waiting", "waiting"]);
		expect(waiting.data.expenses).toHaveLength(3);
		expect(waiting.data.budget).toBeUndefined();
		const allowed = await apps.allow(plan.path);
		expect(allowed.allowed).toBe(true);
		expect(allowed.data.budget).toEqual({ month: 1100 });
	});

	it("what's allowed survives a restart", async () => {
		const { home, root, plan } = await projectApp();
		const again = new Apps({ home, appsDir: join(root, "Piopio", "Apps") });
		expect((await again.refresh(plan.path)).allowed).toBe(true);
	});
});

describe("in the transcript and the Library", () => {
	it("make_app's result is a file card with the app", async () => {
		const details = endDetails("make_app", {}, { details: { files: [{ path: "/p/apps/spending.html", name: "spending.html", description: "App: Spending" }] } }, "Made", false);
		expect(details).toEqual({ type: "files", files: [{ path: "/p/apps/spending.html", name: "spending.html", description: "App: Spending" }] });
		expect(existsSync("/p/apps/spending.html")).toBe(false);
	});
});

describe("the app's conversation and Undo (docs/spec/35 §15)", () => {
	it("one request's edits are one change; Undo puts the page back and keeps the new data", async () => {
		const { apps, plan, csv } = await projectApp();
		const original = readFileSync(plan.path, "utf8");
		apps.noteRequest(plan.path, "Add a budget line at 1.100 €\nand more");
		writeFileSync(plan.path, original.replace('<div id="out"></div>', '<div id="out"></div><hr>'));
		await apps.refresh(plan.path);
		writeFileSync(plan.path, original.replace('<div id="out"></div>', '<div id="out"></div><hr class="budget">'));
		appendFileSync(csv, "2026-11-20,Car,450\n");
		const changed = await apps.refresh(plan.path);
		expect(changed.undo).toMatchObject({ label: "Add a budget line at 1.100 €" });
		const back = apps.undo(plan.path);
		expect(readFileSync(plan.path, "utf8")).toBe(original);
		expect(back.data.expenses).toHaveLength(4);
		expect(back.undo).toBeUndefined();
		expect(() => apps.undo(plan.path)).toThrow(/nothing to undo/);
	});

	it("Undo goes back one request at a time", async () => {
		const { apps, plan } = await projectApp();
		const v0 = readFileSync(plan.path, "utf8");
		apps.noteRequest(plan.path, "First");
		writeFileSync(plan.path, `${v0}<p>1</p>`);
		await apps.refresh(plan.path);
		apps.noteRequest(plan.path, "Second");
		writeFileSync(plan.path, `${v0}<p>1</p><p>2</p>`);
		expect((await apps.refresh(plan.path)).undo?.label).toBe("Second");
		expect(apps.undo(plan.path).undo?.label).toBe("First");
		apps.undo(plan.path);
		expect(readFileSync(plan.path, "utf8")).toBe(v0);
	});

	it("an edit made outside Piopio isn't Undo's, and Undo won't overwrite it without asking", async () => {
		const { apps, plan } = await projectApp();
		const v0 = readFileSync(plan.path, "utf8");
		writeFileSync(plan.path, `${v0}<!-- mine -->`);
		expect((await apps.refresh(plan.path)).undo).toBeUndefined();
		apps.noteRequest(plan.path, "Green bars");
		writeFileSync(plan.path, `${v0}<!-- mine --><p>green</p>`);
		await apps.refresh(plan.path);
		const forgotten = new Apps({ home: join(dirname(plan.path), "..", "..", "home"), appsDir: "/nowhere" });
		writeFileSync(plan.path, `${v0}<!-- mine --><p>green</p><!-- later, in my editor -->`);
		expect(() => forgotten.undo(plan.path)).toThrow(/changed outside Piopio after “Green bars”/);
		forgotten.undo(plan.path, true);
		expect(readFileSync(plan.path, "utf8")).toBe(`${v0}<!-- mine -->`);
	});

	it("tells its conversation where the app is, what it reads, and to answer questions without changing it", async () => {
		const { apps, plan, csv } = await projectApp();
		const text = apps.describe(plan.path);
		expect(text).toContain(`The app “Spending” is the page ${plan.path}`);
		expect(text).toContain(`- expenses: ${csv} (columns date, category, amount)`);
		expect(text).toContain("answer it here, and don't change the app");
		expect(text).toContain("don't read the data for it");
	});
});

describe("what an app may read (audit M1)", () => {
	it("never keys or credentials, even through a symlink in the project", async () => {
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

	// The short hash's fallback (apps allowed before 2026-11-22) went with the alpha migrations on 2026-11-26.
	it("an app allowed only with the old short hash asks again", async () => {
		const { home, apps, plan } = await projectApp();
		const state = JSON.parse(readFileSync(join(home, "apps.json"), "utf8")) as { allowed: Record<string, string> };
		expect(state.allowed[plan.path]).toMatch(/^[0-9a-f]{64}$/);
		const sorted = JSON.stringify(Object.keys(plan.manifest.sources).sort().map((k) => [k, plan.manifest.sources[k]!.file, plan.manifest.sources[k]!.columns ?? []]));
		state.allowed[plan.path] = createHash("sha1").update(sorted).digest("hex").slice(0, 16);
		writeFileSync(join(home, "apps.json"), JSON.stringify(state));
		const again = new Apps({ home, appsDir: join(dirname(home), "Piopio", "Apps") });
		expect((await again.refresh(plan.path)).allowed).toBe(false);
		apps.closeApp(plan.path);
	});
});

describe("calendar sources (docs/spec/35 §16)", () => {
	/** Two connected calendars; `fail` makes one throw, `permission` changes Settings › Connectors. */
	function calendars() {
		const state = {
			accounts: [
				{ id: "google-calendar:me", label: "me@gmail.com", app: "Google Calendar" },
				{ id: "outlook:work", label: "me@work.com", app: "Outlook" },
			],
			fail: new Set<string>(),
			permission: {} as Record<string, "runs" | "ask" | "off">,
			ranges: [] as { from: string; to: string }[],
			events: {
				"google-calendar:me": [{ title: "Dentist", start: "2026-11-24T09:00:00+01:00", end: "2026-11-24T10:00:00+01:00", allDay: false, calendar: "Personal" }],
				"outlook:work": [{ title: "Standup", start: "2026-11-23T09:30:00+01:00", end: "2026-11-23T09:45:00+01:00", allDay: false, location: "Room 2", calendar: "Work" }],
			} as Record<string, { title: string; start: string; end: string; allDay: boolean; location?: string; calendar: string }[]>,
		};
		const access = {
			accounts: () => state.accounts,
			permission: (id: string) => state.permission[id] ?? "runs",
			events: async (id: string, range: { from: string; to: string }) => {
				state.ranges.push(range);
				if (state.fail.has(id)) throw new Error("The server said 503.");
				return state.events[id] ?? [];
			},
		};
		return { state, access };
	}
	const WEEK = `<ul id=l></ul><script>piopio.onData(({ week }) => { l.innerHTML = week.map((e) => "<li>" + e.title).join(""); })</script>`;

	async function calendarApp() {
		const root = folder();
		const cal = calendars();
		const apps = new Apps({ home: join(root, "home"), appsDir: join(root, "Piopio", "Apps"), calendar: cal.access });
		const project = join(root, "p");
		mkdirSync(project);
		const plan = apps.plan({ title: "This week", html: WEEK, sources: { week: { calendar: "this_week" } as never } }, { cwd: project });
		const view = await apps.write(plan);
		return { apps, cal, plan, view, root };
	}

	it("names every connected account on the card, reads each, and hands the page their events in order", async () => {
		const { plan, view, cal } = await calendarApp();
		expect(plan.summary).toBe("Make the app “This week” in apps/this-week.html, reading Google Calendar (me@gmail.com) and Outlook (me@work.com) for this week (Monday to Sunday)");
		expect(plan.manifest.sources.week).toEqual({ calendar: "this_week", accounts: ["google-calendar:me", "outlook:work"] });
		expect(view.data.week).toEqual([
			{ title: "Standup", start: "2026-11-23T09:30:00+01:00", end: "2026-11-23T09:45:00+01:00", allDay: false, location: "Room 2", calendar: "Work", account: "me@work.com" },
			{ title: "Dentist", start: "2026-11-24T09:00:00+01:00", end: "2026-11-24T10:00:00+01:00", allDay: false, calendar: "Personal", account: "me@gmail.com" },
		]);
		expect(view.sources[0]).toMatchObject({ kind: "calendar", file: "Calendar · this week", state: "ok" });
		expect(view.stale).toEqual([]);
		// One span for both: Monday to Monday, local midnight.
		const { from, to } = cal.state.ranges[0]!;
		expect(new Date(from).getDay()).toBe(1);
		expect(new Date(from).getHours()).toBe(0);
		expect(Date.parse(to) - Date.parse(from)).toBeGreaterThanOrEqual(7 * 86_400_000 - 3_600_000);
	});

	it("one account failing keeps its last good events, dated, and says which", async () => {
		const { apps, plan, cal, view: first } = await calendarApp();
		cal.state.fail.add("google-calendar:me");
		cal.state.events["outlook:work"]!.push({ title: "Review", start: "2026-11-25T15:00:00+01:00", end: "2026-11-25T16:00:00+01:00", allDay: false, calendar: "Work" });
		const view = await apps.refresh(plan.path);
		expect((view.data.week as { title: string }[]).map((e) => e.title)).toEqual(["Standup", "Dentist", "Review"]);
		const google = view.sources[0]!.accounts!.find((a) => a.id === "google-calendar:me")!;
		expect(google).toMatchObject({ state: "failed", error: "Google Calendar (me@gmail.com): The server said 503.", readAt: first.sources[0]!.accounts![0]!.readAt });
		expect(view.sources[0]).toMatchObject({ state: "failed", error: "Google Calendar (me@gmail.com): The server said 503." });
		expect(view.stale).toEqual(["week"]);
	});

	it("an account that's disconnected takes its events with it, at once", async () => {
		const { apps, plan, cal } = await calendarApp();
		cal.state.accounts = cal.state.accounts.filter((a) => a.id !== "outlook:work");
		const view = apps.openApp(plan.path);
		expect((view.data.week as { title: string }[]).map((e) => e.title)).toEqual(["Dentist"]);
		expect(view.sources[0]!.accounts!.find((a) => a.id === "outlook:work")).toMatchObject({ state: "gone" });
		// Not just hidden: reconnecting it doesn't bring the old events back before a new read.
		cal.state.accounts.push({ id: "outlook:work", label: "me@work.com", app: "Outlook" });
		const back = apps.openApp(plan.path);
		expect((back.data.week as { title: string }[]).map((e) => e.title)).toEqual(["Dentist"]);
		apps.stop();
	});

	it("reading off or asking first in Settings › Connectors: that account isn't read and keeps nothing", async () => {
		const { apps, plan, cal } = await calendarApp();
		cal.state.permission["outlook:work"] = "off";
		cal.state.permission["google-calendar:me"] = "ask";
		const before = cal.state.ranges.length;
		const view = await apps.refresh(plan.path);
		expect(cal.state.ranges.length).toBe(before);
		expect(view.data.week).toBeUndefined();
		expect(view.sources[0]!.error).toContain("Reading Outlook (me@work.com) is off in Settings › Connectors");
		expect(view.sources[0]!.error).toContain("Reading Google Calendar (me@gmail.com) asks first");
	});

	it("an account connected later isn't read until the app is changed and allowed again", async () => {
		const { apps, plan, cal } = await calendarApp();
		cal.state.accounts.push({ id: "google-calendar:other", label: "other@gmail.com", app: "Google Calendar" });
		cal.state.events["google-calendar:other"] = [{ title: "Secret", start: "2026-11-26T10:00:00+01:00", end: "2026-11-26T11:00:00+01:00", allDay: false, calendar: "Other" }];
		const view = await apps.refresh(plan.path);
		expect((view.data.week as { title: string }[]).some((e) => e.title === "Secret")).toBe(false);
		// The page names it now: that's a different list of sources, which waits for Allow.
		writeFileSync(plan.path, readFileSync(plan.path, "utf8").replace('"outlook:work"', '"outlook:work",\n\t\t\t\t"google-calendar:other"'));
		const waiting = await apps.refresh(plan.path);
		expect(waiting.allowed).toBe(false);
		expect((await apps.allow(plan.path)).data.week).toHaveLength(3);
	});

	// Re-audit 2026-11-25 V7: an app opened without a new read still showed an account's events after its reading was set to Off.
	it("set to Off or Ask in Settings › Connectors: an app opened without a read shows nothing of that account", async () => {
		const { apps, plan, cal } = await calendarApp();
		expect((apps.openApp(plan.path).data.week as unknown[]).length).toBe(2);
		cal.state.permission["outlook:work"] = "off";
		const opened = apps.openApp(plan.path);
		expect((opened.data.week as { title: string }[]).map((e) => e.title)).toEqual(["Dentist"]);
		expect(opened.sources[0]!.error).toContain("Reading Outlook (me@work.com) is off");
		// Back to Runs: nothing comes back before a new read.
		cal.state.permission["outlook:work"] = "runs";
		expect((apps.openApp(plan.path).data.week as { title: string }[]).map((e) => e.title)).toEqual(["Dentist"]);
		apps.stop();
	});

	it("Stop reading forgets what it read and waits for Allow", async () => {
		const { apps, plan } = await calendarApp();
		const stopped = apps.revoke(plan.path);
		expect(stopped.allowed).toBe(false);
		expect(stopped.data.week).toBeUndefined();
		expect(stopped.sources[0]!.state).toBe("waiting");
		expect((await apps.allow(plan.path)).data.week).toHaveLength(2);
	});

	it("refuses an account that isn't connected, and a calendar source when none is", () => {
		const root = folder();
		const none = new Apps({ home: join(root, "home"), appsDir: join(root, "Apps"), calendar: { accounts: () => [], permission: () => "runs", events: async () => [] } });
		expect(() => none.plan({ title: "W", html: WEEK, sources: { week: { calendar: "today" } as never } }, { cwd: root })).toThrow(/no calendar is connected/);
		const { access } = calendars();
		const some = new Apps({ home: join(root, "home2"), appsDir: join(root, "Apps"), calendar: access });
		expect(() => some.plan({ title: "W", html: WEEK, sources: { week: { calendar: "today", accounts: ["outlook:gone"] } as never } }, { cwd: root })).toThrow(/outlook:gone isn't a connected calendar account/);
		expect(() => some.plan({ title: "W", html: WEEK, sources: { week: { calendar: "next_year" } as never } }, { cwd: root })).toThrow(/calendar is one of/);
	});

	it("spans start at local midnight; weeks on Monday", () => {
		const sunday = new Date(2026, 10, 29, 18, 30);
		const week = calendarSpan("this_week", sunday);
		expect(new Date(week.from)).toEqual(new Date(2026, 10, 23));
		expect(new Date(week.to)).toEqual(new Date(2026, 10, 30));
		expect(calendarSpan("tomorrow", sunday)).toEqual({ from: new Date(2026, 10, 30).toISOString(), to: new Date(2026, 11, 1).toISOString() });
		expect(calendarSpan("this_month", sunday)).toEqual({ from: new Date(2026, 10, 1).toISOString(), to: new Date(2026, 11, 1).toISOString() });
		expect(Date.parse(calendarSpan("next_7_days", sunday).to) - sunday.getTime()).toBe(7 * 86_400_000);
	});
});

describe("Piopio's own numbers (docs/spec/35 L4)", () => {
	const SPEND = `<b id=t></b><script>piopio.onData(({ spend }) => { t.textContent = spend.knownUsd; })</script>`;
	function withPiopio() {
		const root = folder();
		const reads: { what: string; args: Record<string, unknown> }[] = [];
		const state = { usd: 12.5, fail: false };
		const apps = new Apps({
			home: join(root, "home"),
			appsDir: join(root, "Piopio", "Apps"),
			piopio: {
				read: async (what, args) => {
					reads.push({ what, args });
					if (state.fail) throw new Error("The ledger is busy.");
					return what === "stats.spend" ? { knownUsd: state.usd, calls: 3 } : [];
				},
			},
		});
		return { root, apps, reads, state };
	}

	it("reads them with no model, says so on the card, and keeps the last good numbers when a read fails", async () => {
		const { root, apps, reads, state } = withPiopio();
		const plan = apps.plan({ title: "Spend", html: SPEND, sources: { spend: { piopio: "stats.spend", args: { groupBy: "what" } } as never } }, { cwd: root });
		expect(plan.manifest.sources.spend).toEqual({ piopio: "stats.spend", args: { groupBy: "what", range: "month" } });
		expect(plan.card.reads).toEqual(["what Piopio spent this month, by what"]);
		expect(plan.card.refresh).toMatch(/no model/);
		const made = await apps.write(plan);
		expect(made.data.spend).toEqual({ knownUsd: 12.5, calls: 3 });
		expect(made.sources[0]).toMatchObject({ kind: "piopio", file: "Piopio · what Piopio spent this month, by what", state: "ok" });
		expect(reads).toEqual([{ what: "stats.spend", args: { groupBy: "what", range: "month" } }]);

		state.usd = 14;
		expect((await apps.refresh(plan.path)).data.spend).toEqual({ knownUsd: 14, calls: 3 });
		state.fail = true;
		const failed = await apps.refresh(plan.path);
		expect(failed.data.spend).toEqual({ knownUsd: 14, calls: 3 });
		expect(failed.sources[0]).toMatchObject({ state: "failed", error: "The ledger is busy." });
		expect(failed.stale).toEqual(["spend"]);

		// A changed source (another range) waits for Allow, like a file or a calendar.
		writeFileSync(plan.path, readFileSync(plan.path, "utf8").replace('"range": "month"', '"range": "12m"'));
		expect(apps.openApp(plan.path).allowed).toBe(false);
		apps.closeApp(plan.path);

		// The app's conversation is told what the source gives.
		expect(apps.describe(plan.path)).toMatch(/spend: what Piopio spent the last 12 months, by what, read from Piopio with no model \(stats\.spend .*\): \{ knownUsd/);
	});

	it("takes only what each read allows", () => {
		const { root, apps } = withPiopio();
		const plan = (sources: Record<string, unknown>) => () => apps.plan({ title: "P", html: SPEND, sources: sources as never }, { cwd: root });
		expect(plan({ spend: { piopio: "sessions.list" } })).toThrow(/piopio is one of stats\.spend/);
		expect(plan({ spend: { piopio: "stats.spend", args: { range: "forever" } } })).toThrow(/range is one of/);
		expect(plan({ spend: { piopio: "stats.spend", args: { groupBy: "mood" } } })).toThrow(/groupBy is one of/);
		expect(plan({ spend: { piopio: "stats.budgets", args: { range: "month" } } })).toThrow(/stats\.budgets takes no “range”/);
		expect(plan({ runs: { piopio: "automations.runs", args: { limit: 500 } } })).toThrow(/limit is a number from 1 to 100/);
		expect(plan({ spend: { piopio: "stats.spend", args: { filter: { agent: "rita", secret: "x" } } } })).toThrow(/filter is/);
		expect(plan({ runs: { piopio: "automations.runs", args: { limit: 10 } }, agents: { piopio: "agents" } })().card.reads).toEqual(["your automations' latest runs", "your agents and their status"]);
	});
});
