import { existsSync, mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { afterEach, describe, expect, it } from "vitest";
import { Engine } from "../src/server.js";
import { enginePaths } from "../src/paths.js";
import { checkUrl } from "../src/tools/browser-tools.js";

const dirs: string[] = [];
afterEach(() => {
	for (const dir of dirs.splice(0)) rmSync(dir, { recursive: true, force: true });
});

describe("the browser's URL check (docs/spec/22 §4.1)", () => {
	it("opens only http(s), and no local or private address", async () => {
		expect(await checkUrl("file:///etc/passwd")).toContain("only http and https");
		expect(await checkUrl("javascript:alert(1)")).toContain("only http and https");
		expect(await checkUrl("http://127.0.0.1:3000/")).toContain("local or private");
		expect(await checkUrl("http://192.168.1.10/")).toContain("local or private");
		expect(await checkUrl("http://localhost/")).toContain("local or private");
		expect(await checkUrl("http://127.0.0.1:3000/", true)).toBeUndefined();
		expect(await checkUrl("not a url")).toContain("Not a URL");
	});
});

