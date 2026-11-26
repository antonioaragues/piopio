/**
 * Writes the protocol's JSON Schema (src/schema.ts) and its samples (src/samples.ts) beside it, and the Mac app's Swift
 * types (src/swift.ts): `pnpm schema` keeps schema/protocol.schema.json, schema/protocol.samples.json and
 * apps/mac/Sources/PiopioKit/Protocol.generated.swift current (test/schema.test.ts and test/swift.test.ts check them).
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";
import { protocolSamplesText } from "./samples.js";
import { protocolSchemaText } from "./schema.js";
import { protocolSwiftText, SWIFT_FILE } from "./swift.js";

const out = process.argv[2] ?? "schema/protocol.schema.json";
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, protocolSchemaText());
const samples = join(dirname(out), "protocol.samples.json");
writeFileSync(samples, protocolSamplesText());
const swift = fileURLToPath(SWIFT_FILE);
writeFileSync(swift, protocolSwiftText());
console.log(`wrote ${out}, ${samples} and ${swift}`);
