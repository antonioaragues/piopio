import { readFileSync } from "node:fs";
import { expect, test } from "vitest";
import * as P from "../src/index.js";
import { protocolSwiftText, SWIFT_FILE } from "../src/swift.js";

// The Mac app's protocol types are generated (re-audit 2026-11-25 §4: 221 methods' Swift types were kept in step by
// hand). A protocol change that isn't regenerated fails here, not in the app at run time.
test("apps/mac/Sources/PiopioKit/Protocol.generated.swift is the protocol as it is (run `corepack pnpm schema` from the repository root and commit it)", () => {
	const committed = readFileSync(SWIFT_FILE, "utf8");
	expect(committed === protocolSwiftText(), "The Swift types are stale: run `corepack pnpm schema` and commit apps/mac/Sources/PiopioKit/Protocol.generated.swift.").toBe(true);
});

// A schema without a title is inlined wherever it's used, so Swift gets a copy per place instead of one type.
test("every exported schema is named after itself (`export const X = named(\"X\", …)`)", () => {
	const unnamed = Object.entries(P)
		.filter(([, v]) => typeof v === "object" && v !== null && "~kind" in v)
		.filter(([name, v]) => (v as { title?: string }).title !== name)
		.map(([name]) => name);
	expect(unnamed).toEqual([]);
});
