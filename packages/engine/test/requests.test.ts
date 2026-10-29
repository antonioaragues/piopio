import { mkdtempSync, rmSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { expect, test } from "vitest";
import { InputReceipts } from "../src/requests.js";

test("a lost response is safe to retry concurrently and after restart", async () => {
	const home = mkdtempSync(join(tmpdir(), "piopio-receipts-"));
	let receipts = new InputReceipts(join(home, "requests.db"));
	let runs = 0;
	const execute = async () => { runs++; await new Promise(resolve => setTimeout(resolve, 10)); return { accepted: true }; };
	try {
		const payload = { method: "sessions.submit", ref: "a", text: "hello" };
		expect(await Promise.all([receipts.run("r1", payload, execute), receipts.run("r1", payload, execute)])).toEqual([{ accepted: true }, { accepted: true }]);
		expect(runs).toBe(1);
		receipts.close(); receipts = new InputReceipts(join(home, "requests.db"));
		expect(await receipts.run("r1", payload, execute)).toEqual({ accepted: true }); expect(runs).toBe(1);
		await expect(receipts.run("r1", { ...payload, text: "changed" }, execute)).rejects.toThrow("different message");
		await expect(receipts.run("r2", payload, async () => { throw new Error("offline"); })).rejects.toThrow("offline");
		await receipts.run("r2", payload, execute); expect(runs).toBe(2);
	} finally { receipts.close(); rmSync(home, { recursive: true }); }
});
