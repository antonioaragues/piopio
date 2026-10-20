import { execFileSync } from "node:child_process";
import { existsSync, mkdirSync, mkdtempSync, readFileSync, realpathSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { CheckpointStore } from "../src/checkpoints.js";

function folder() {
	const dir = realpathSync(mkdtempSync(join(tmpdir(), "piopio-cp-")));
	execFileSync("git", ["init", "-q", "-b", "main"], { cwd: dir });
	writeFileSync(join(dir, ".gitignore"), "ignored.log\n");
	writeFileSync(join(dir, "a.txt"), "one\ntwo\n");
	writeFileSync(join(dir, "keep.txt"), "keep\n");
	writeFileSync(join(dir, "untracked.txt"), "never committed by the user\n");
	return dir;
}

test("snapshots include untracked files, skip ignored ones, and restore puts everything back", async () => {
	const dir = folder();
	const store = new CheckpointStore(mkdtempSync(join(tmpdir(), "piopio-cp-store-")));
	const userHead = execFileSync("git", ["status", "--porcelain"], { cwd: dir, encoding: "utf8" });

	const first = await store.snapshot(dir, "Session start");
	expect(first.files).toBe(0);
	writeFileSync(join(dir, "a.txt"), "one\nTWO\nthree\n");
	writeFileSync(join(dir, "new.txt"), "new\n");
	writeFileSync(join(dir, "ignored.log"), "noise\n");
	execFileSync("rm", [join(dir, "untracked.txt")]);
	mkdirSync(join(dir, "node_modules"));
	writeFileSync(join(dir, "node_modules", "x.js"), "x\n");

	expect(await store.changes(dir, first.id)).toEqual([
		{ path: "a.txt", status: "modified", added: 2, removed: 1 },
		{ path: "new.txt", status: "added", added: 1, removed: 0 },
		{ path: "untracked.txt", status: "deleted", added: 0, removed: 1 },
	]);
	expect(await store.diff(dir, first.id, "a.txt")).toContain("-two\n+TWO\n+three");

	const second = await store.snapshot(dir, "Before turn 2");
	expect(second.files).toBe(3);

	// One file back, then the whole folder.
	expect((await store.restore(dir, first.id, ["a.txt"])).map((c) => c.path)).toEqual(["a.txt"]);
	expect(readFileSync(join(dir, "a.txt"), "utf8")).toBe("one\ntwo\n");
	expect(existsSync(join(dir, "new.txt"))).toBe(true);
	const undone = await store.restore(dir, first.id);
	expect(undone.map((c) => `${c.status} ${c.path}`)).toEqual(["added new.txt", "deleted untracked.txt"]);
	expect(existsSync(join(dir, "new.txt"))).toBe(false);
	expect(readFileSync(join(dir, "untracked.txt"), "utf8")).toBe("never committed by the user\n");
	expect(existsSync(join(dir, "ignored.log"))).toBe(true);
	expect(existsSync(join(dir, "node_modules", "x.js"))).toBe(true);
	expect(await store.changes(dir, first.id)).toEqual([]);

	// The second checkpoint still restores the later state.
	await store.restore(dir, second.id);
	expect(readFileSync(join(dir, "a.txt"), "utf8")).toBe("one\nTWO\nthree\n");

	// The user's repository is untouched (same status as before, plus our own edits to the files).
	expect(execFileSync("git", ["rev-list", "--all", "--count"], { cwd: dir, encoding: "utf8" }).trim()).toBe("0");
	expect(userHead).toContain("?? a.txt");
	await expect(store.restore(dir, "deadbeef")).rejects.toMatchObject({ code: "NOT_FOUND" });
});
