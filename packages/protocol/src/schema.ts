/**
 * The protocol as one JSON Schema document: what the Swift side is checked against (docs/spec/03-engine-protocol.md).
 * `schema/protocol.schema.json` is this, written by `pnpm schema`; test/schema.test.ts fails when they differ, so a
 * change to the protocol and its schema land together.
 */
import * as P from "./index.js";

export function protocolSchema(): Record<string, unknown> {
	const definitions: Record<string, unknown> = {
		ContainerRef: P.ContainerRef,
		TimelineItem: P.TimelineItem,
		SessionState: P.SessionState,
		SessionEvent: P.SessionEvent,
		Snapshot: P.Snapshot,
		SessionSummary: P.SessionSummary,
		SessionEventsNotification: P.SessionEventsNotification,
		ModelInfo: P.ModelInfo,
		CatalogChanged: P.CatalogChanged,
	};
	for (const [name, m] of Object.entries(P.methods)) {
		definitions[`${name}.params`] = m.params;
		definitions[`${name}.result`] = m.result;
	}
	for (const [name, m] of Object.entries(P.reverseMethods)) {
		definitions[`${name}.params`] = m.params;
		definitions[`${name}.result`] = m.result;
	}
	// What the engine sends unasked: the app decodes several with `try?`, so a mismatch drops them without a word.
	for (const [name, params] of Object.entries(P.notifications)) definitions[`${name}.notification`] = params;
	return { $schema: "https://json-schema.org/draft/2020-12/schema", title: "Piopio Engine Protocol", version: P.PROTOCOL_VERSION, definitions };
}

/** The file's text: tabs, a final new line. */
export function protocolSchemaText(): string {
	return `${JSON.stringify(protocolSchema(), null, "\t")}\n`;
}
