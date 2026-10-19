import { mkdtempSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import type { TimelineItem } from "@piopio/protocol";
import { expect, test } from "vitest";
import { SearchIndex, toMatch } from "../src/search.js";

const user = (id: string, text: string): TimelineItem => ({ kind: "user", id, at: "2026-10-19T10:00:00Z", text });
const answer = (id: string, text: string, status: "done" | "streaming" = "done"): TimelineItem => ({ kind: "assistant", id, at: "2026-10-19T10:00:01Z", parts: [{ type: "text", text }], status });

test("query words are prefix-matched and sanitized", () => {
	expect(toMatch('dura obj"ect')).toBe('"dura"* "object"*');
	expect(toMatch("  ")).toBeUndefined();
});

test("indexes sessions, finds words with highlights, and follows updates", () => {
	const index = new SearchIndex(join(mkdtempSync(join(tmpdir(), "piopio-search-")), "search.db"));
	index.replaceSession("a", "Kitchen plans", "t", [user("1", "Can the café fit a dishwasher?"), answer("2", "Yes, with a 60 cm cabinet."), answer("3", "partial", "streaming")]);
	index.replaceSession("b", "Rust notes", "t", [user("1", "Explain borrowing")]);
	expect(index.isIndexed("a")).toBe(true);

	const hits = index.search("cafe dish");
	expect(hits).toHaveLength(1);
	expect(hits[0]).toMatchObject({ sessionId: "a", itemId: "1", kind: "user" });
	expect(hits[0]!.snippet).toContain("\u0002café\u0003");
	expect(index.search("kitchen")[0]).toMatchObject({ sessionId: "a", kind: "title", itemId: null });
	expect(index.search("partial")).toEqual([]);

	index.upsertItem("a", answer("9", "Dishwashers need 60 cm."), "3");
	expect(index.search("dishwashers")[0]).toMatchObject({ itemId: "9" });
	index.setTitle("b", "Ownership notes", "t");
	expect(index.search("rust")).toEqual([]);
	expect(index.search("ownership")[0]).toMatchObject({ sessionId: "b", kind: "title" });
	index.deleteSession("a");
	expect(index.search("cabinet")).toEqual([]);
	index.close();
});
