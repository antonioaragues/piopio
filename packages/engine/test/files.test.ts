import { mkdirSync, mkdtempSync, readFileSync, realpathSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { readProjectFile, writeProjectFile } from "../src/files.js";

// The file viewer opens what a repository ships: a symlink in it can point anywhere (audit M1, 2026-11-22).
const root = realpathSync(mkdtempSync(join(tmpdir(), "piopio-files-")));
const project = join(root, "project");
const outside = join(root, "outside");
mkdirSync(join(project, "src"), { recursive: true });
mkdirSync(outside);
writeFileSync(join(project, "src", "a.ts"), "a");
writeFileSync(join(outside, "secret.txt"), "secret");
symlinkSync(join(outside, "secret.txt"), join(project, "notes.md"));
symlinkSync(outside, join(project, "linked"));
symlinkSync(join(project, "src"), join(project, "inner"));

test("the viewer reads and writes files whose real location is in the project, links inside it included", async () => {
	expect((await readProjectFile(project, "src/a.ts")).content).toBe("a");
	expect((await readProjectFile(project, "inner/a.ts")).content).toBe("a");
	await writeProjectFile(project, "inner/a.ts", "b");
	expect(readFileSync(join(project, "src", "a.ts"), "utf8")).toBe("b");
});

test("a link to somewhere outside the project is refused for reading and writing, as is a path spelled outside", async () => {
	for (const path of ["notes.md", "linked/secret.txt"]) {
		await expect(readProjectFile(project, path), path).rejects.toThrow(/outside the project/);
		await expect(writeProjectFile(project, path, "x"), path).rejects.toThrow(/outside the project/);
	}
	await expect(readProjectFile(project, "../outside/secret.txt")).rejects.toThrow(/outside the project/);
	expect(readFileSync(join(outside, "secret.txt"), "utf8")).toBe("secret");
});
