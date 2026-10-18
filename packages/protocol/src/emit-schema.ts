/** Writes the protocol as one JSON Schema document (input for Swift codegen). */
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname } from "node:path";
import * as P from "./index.js";

const out = process.argv[2] ?? "schema/protocol.schema.json";

const definitions: Record<string, unknown> = {
	ContainerRef: P.ContainerRef,
	TimelineItem: P.TimelineItem,
	SessionState: P.SessionState,
	SessionEvent: P.SessionEvent,
	Snapshot: P.Snapshot,
	SessionSummary: P.SessionSummary,
	SessionEventsNotification: P.SessionEventsNotification,
};
for (const [name, m] of Object.entries(P.methods)) {
	definitions[`${name}.params`] = m.params;
	definitions[`${name}.result`] = m.result;
}
for (const [name, m] of Object.entries(P.reverseMethods)) {
	definitions[`${name}.params`] = m.params;
	definitions[`${name}.result`] = m.result;
}

mkdirSync(dirname(out), { recursive: true });
writeFileSync(
	out,
	`${JSON.stringify({ $schema: "https://json-schema.org/draft/2020-12/schema", title: "Piopio Engine Protocol", version: P.PROTOCOL_VERSION, definitions }, null, "\t")}\n`,
);
console.log(`wrote ${out}`);
