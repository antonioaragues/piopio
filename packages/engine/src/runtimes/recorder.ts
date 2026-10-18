/** Appends raw upstream events to `$PIOPIO_RECORD_DIR/<runtime>-<session>.jsonl` (fixtures for mapper tests). */
import { appendFileSync, mkdirSync } from "node:fs";
import { join } from "node:path";

export function recorder(runtime: "pi-sdk" | "pi-durable", sessionId: string): ((event: unknown) => void) | undefined {
	const dir = process.env.PIOPIO_RECORD_DIR;
	if (!dir) return undefined;
	mkdirSync(dir, { recursive: true });
	const file = join(dir, `${runtime}-${sessionId}.jsonl`);
	return (event) => appendFileSync(file, `${JSON.stringify(event)}\n`);
}
