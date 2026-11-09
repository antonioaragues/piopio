import { execFileSync } from "node:child_process";
import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { log, parseLog, parseNumstat, status } from "../src/git.js";

test("numstat: counts per path, none for binary files", () => {
	const m = parseNumstat("12\t3\tsrc/a.ts\n-\t-\timg.png\nnot a line\n");
	expect(m.get("src/a.ts")).toEqual({ added: 12, removed: 3 });
	expect(m.get("img.png")).toEqual({});
	expect(m.size).toBe(2);
});

test("log: each commit with the files it touched (the Inspector's timeline)", () => {
	const out = "\x1eaaa\x1fSecond\x1f2026-11-09T21:00:00+01:00\n\n4\t1\tsrc/a.ts\n2\t0\tdocs/b.md\n\x1ebbb\x1fFirst\x1f2026-11-09T20:00:00+01:00\n\n1\t0\tREADME.md\n";
	expect(parseLog(out)).toEqual([
		{ hash: "aaa", subject: "Second", at: "2026-11-09T21:00:00+01:00", files: [{ path: "src/a.ts", added: 4, removed: 1 }, { path: "docs/b.md", added: 2, removed: 0 }] },
		{ hash: "bbb", subject: "First", at: "2026-11-09T20:00:00+01:00", files: [{ path: "README.md", added: 1, removed: 0 }] },
	]);
});

test("a real repo: commits with their files, and +/− for what isn't saved yet", async () => {
	const dir = mkdtempSync(join(tmpdir(), "piopio-gitlog-"));
	const run = (...args: string[]) => execFileSync("git", args, { cwd: dir, env: { ...process.env, GIT_AUTHOR_NAME: "T", GIT_AUTHOR_EMAIL: "t@t", GIT_COMMITTER_NAME: "T", GIT_COMMITTER_EMAIL: "t@t" } });
	run("init", "-q", "-b", "main");
	writeFileSync(join(dir, "a.txt"), "one\ntwo\n");
	run("add", "-A");
	run("commit", "-qm", "Add a");
	writeFileSync(join(dir, "a.txt"), "one\nthree\nfour\n");
	writeFileSync(join(dir, "new.md"), "# New\n\nText\n");
	const commits = await log(dir);
	expect(commits).toHaveLength(1);
	expect(commits[0]!.files).toEqual([{ path: "a.txt", added: 2, removed: 0 }]);
	const s = await status(dir);
	expect(s.files.find((f) => f.path === "a.txt")).toMatchObject({ status: "modified", added: 2, removed: 1 });
	expect(s.files.find((f) => f.path === "new.md")).toMatchObject({ status: "untracked", added: 3, removed: 0 });
});
