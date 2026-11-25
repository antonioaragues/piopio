import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { expect, test } from "vitest";
import { protocolSamplesText } from "../src/samples.js";
import { protocolSchemaText } from "../src/schema.js";

const committed = (file: string) => readFileSync(fileURLToPath(new URL(`../schema/${file}`, import.meta.url)), "utf8");

// Re-audit 2026-11-25: the committed schema was 57 methods behind the protocol, and nothing noticed.
test("schema/protocol.schema.json is the protocol as it is (run `corepack pnpm schema` from the repository root and commit it)", () => {
	const file = committed("protocol.schema.json");
	const current = protocolSchemaText();
	if (file === current) return;
	const was = (JSON.parse(file) as { definitions: Record<string, unknown> }).definitions;
	const now = (JSON.parse(current) as { definitions: Record<string, unknown> }).definitions;
	const added = Object.keys(now).filter((k) => !(k in was));
	const removed = Object.keys(was).filter((k) => !(k in now));
	const changed = Object.keys(now).filter((k) => k in was && JSON.stringify(now[k]) !== JSON.stringify(was[k]));
	expect({ added, removed, changed }, "The schema is stale: run `corepack pnpm schema` and commit packages/protocol/schema/protocol.schema.json.").toEqual({ added: [], removed: [], changed: [] });
	expect(file).toBe(current);
});

test("schema/protocol.samples.json, which the Swift contract test decodes, is current too (`corepack pnpm schema`)", () => {
	expect(committed("protocol.samples.json") === protocolSamplesText(), "The samples are stale: run `corepack pnpm schema` and commit packages/protocol/schema/protocol.samples.json.").toBe(true);
});
