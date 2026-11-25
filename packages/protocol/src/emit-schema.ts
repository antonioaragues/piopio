/**
 * Writes the protocol's JSON Schema (src/schema.ts) and its samples (src/samples.ts) beside it: `pnpm schema` keeps
 * schema/protocol.schema.json and schema/protocol.samples.json current (test/schema.test.ts checks both).
 */
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { protocolSamplesText } from "./samples.js";
import { protocolSchemaText } from "./schema.js";

const out = process.argv[2] ?? "schema/protocol.schema.json";
mkdirSync(dirname(out), { recursive: true });
writeFileSync(out, protocolSchemaText());
const samples = join(dirname(out), "protocol.samples.json");
writeFileSync(samples, protocolSamplesText());
console.log(`wrote ${out} and ${samples}`);
