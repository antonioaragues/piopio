import { existsSync, mkdtempSync, readdirSync, readFileSync, statSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { readJsonFile, writeFileAtomic } from "../src/atomic.js";
import { Settings } from "../src/settings.js";

test("atomic writes leave no temporary file and keep the mode", () => {
	const dir = mkdtempSync(join(tmpdir(), "piopio-atomic-"));
	const file = join(dir, "store.json");
	writeFileAtomic(file, "[1]", { mode: 0o600 });
	writeFileAtomic(file, "[2]", { mode: 0o600 });
	expect(readFileSync(file, "utf8")).toBe("[2]");
	expect(statSync(file).mode & 0o777).toBe(0o600);
	expect(readdirSync(dir)).toEqual(["store.json"]);
});

test("a JSON file that doesn't parse is moved aside, and the engine starts without it", () => {
	const dir = mkdtempSync(join(tmpdir(), "piopio-atomic-"));
	const file = join(dir, "settings.json");
	expect(readJsonFile(file, () => "none")).toBe("none");
	writeFileSync(file, '{"chat": {"web": tru');
	const settings = new Settings(file);
	expect(settings.get().chat).toBeDefined();
	expect(existsSync(file)).toBe(false);
	const aside = readdirSync(dir).find((f) => f.startsWith("settings.json.corrupt-"));
	expect(aside && readFileSync(join(dir, aside), "utf8")).toBe('{"chat": {"web": tru');
});
