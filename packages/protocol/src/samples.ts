/**
 * Sample values of every definition in the protocol's schema (src/schema.ts), for the Swift side's contract test
 * (apps/mac/Tests/PiopioKitTests/ProtocolContractTests.swift), which decodes each one into the type the app reads it
 * as. The samples are what the engine may send, so a Swift type that fails one is wrong in a way the app only finds
 * at run time, often silently (a `try?` turns it into nil): a field Swift requires that the engine can leave out, an
 * enum value Swift doesn't know, a number where Swift expects a string.
 *
 * Per definition: one sample with the required fields only, then samples with every field, the k-th taking the k-th
 * branch of each union (modulo its size), so every branch of a definition's widest union shows up at least once.
 * Values are placeholders ("x", 1, true): the shape is what's checked, not the content.
 * `schema/protocol.samples.json` is this, written by `pnpm schema`; test/schema.test.ts fails when it's stale.
 */
import { protocolSchema } from "./schema.js";

type Schema = {
	type?: string;
	const?: unknown;
	properties?: Record<string, Schema>;
	required?: string[];
	anyOf?: Schema[];
	allOf?: Schema[];
	items?: Schema;
	patternProperties?: Record<string, Schema>;
};

/** The widest union anywhere in `s`: how many full samples it takes to see each of its branches. */
function widest(s: Schema): number {
	let n = s.anyOf?.length ?? 1;
	for (const child of [...(s.anyOf ?? []), ...(s.allOf ?? []), ...Object.values(s.properties ?? {}), ...Object.values(s.patternProperties ?? {}), ...(s.items ? [s.items] : [])]) n = Math.max(n, widest(child));
	return n;
}

function sample(s: Schema, k: number, full: boolean): unknown {
	if ("const" in s) return s.const;
	if (s.anyOf) return sample(s.anyOf[k % s.anyOf.length]!, k, full);
	// Type.Intersect: one object with every part's fields (a later part's wins, as it tightens one).
	if (s.allOf) return Object.assign({}, ...s.allOf.map((part) => sample(part, k, full)));
	switch (s.type) {
		case "string":
			return "x";
		case "number":
		case "integer":
			return 1;
		case "boolean":
			return true;
		case "null":
			return null;
		case "array":
			return s.items ? [sample(s.items, k, full)] : [];
		case "object": {
			const out: Record<string, unknown> = {};
			for (const [name, child] of Object.entries(s.properties ?? {})) if (full || s.required?.includes(name)) out[name] = sample(child, k, full);
			for (const child of Object.values(s.patternProperties ?? {})) out.key = sample(child, k, full);
			return out;
		}
		default:
			// Type.Unknown(): anything. An object, the most a decoder could choke on.
			return { any: [1, "x"] };
	}
}

/** The samples of one schema: required fields only, then every field across its union branches; no repeats. */
export function samplesOf(s: Schema): unknown[] {
	const all = [sample(s, 0, false), ...Array.from({ length: widest(s) }, (_, k) => sample(s, k, true))];
	const seen = new Set<string>();
	return all.filter((v) => {
		const key = JSON.stringify(v);
		if (seen.has(key)) return false;
		seen.add(key);
		return true;
	});
}

export function protocolSamples(): Record<string, unknown[]> {
	const definitions = protocolSchema().definitions as Record<string, Schema>;
	return Object.fromEntries(Object.entries(definitions).map(([name, s]) => [name, samplesOf(s)]));
}

/** The file's text: one definition per line, so a change reads as a change to that definition. */
export function protocolSamplesText(): string {
	const entries = Object.entries(protocolSamples()).map(([name, values]) => `\t${JSON.stringify(name)}: ${JSON.stringify(values)}`);
	return `{\n${entries.join(",\n")}\n}\n`;
}
