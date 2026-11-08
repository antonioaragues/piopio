import { mkdtempSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { presentedFilesSettled } from "../src/present.js";

test("a file still being written in the same step is waited for, a wrong path isn't found", async () => {
	const dir = mkdtempSync(join(tmpdir(), "piopio-present-"));
	setTimeout(() => writeFileSync(join(dir, "report.md"), "# Report"), 300);
	const files = await presentedFilesSettled(dir, [{ path: "report.md" }, { path: "nope.md" }], 1_000);
	expect(files[0]).toMatchObject({ name: "report.md", size: 8 });
	expect(files[0]!.missing).toBeUndefined();
	expect(files[1]).toMatchObject({ name: "nope.md", missing: true });
});
