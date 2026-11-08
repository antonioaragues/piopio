/**
 * Oversized tool output (docs/research/deepseek-harness.md §2.6). pi-durable bounds a result by keeping its start (or
 * its end), so an error at the bottom of a long log, or the summary at the end of a test run, is lost. Here a result
 * over the budget keeps both ends, cut at line breaks, with a marker saying how much of the middle went. In Build,
 * `save` may write the whole result to a file and the marker names it, so the model can read the part it needs.
 */

/** Under pi-durable's own bound (50 KB, 2,000 lines), so it doesn't cut again. */
export const KEEP_CHARS = 40_000;
export const KEEP_LINES = 1_800;

export type Kept = { text: string; cut: boolean; cutChars: number; cutLines: number };

/** The text with its start (2/3 of the budget) and end (1/3) when it's over `maxChars` or `maxLines`. */
export function keepEnds(text: string, options: { maxChars?: number; maxLines?: number; file?: string } = {}): Kept {
	const maxChars = options.maxChars ?? KEEP_CHARS;
	const maxLines = options.maxLines ?? KEEP_LINES;
	const lines = text.split("\n");
	if (text.length <= maxChars && lines.length <= maxLines) return { text, cut: false, cutChars: 0, cutLines: 0 };
	const headBudget = Math.floor((maxChars * 2) / 3);
	const tailBudget = maxChars - headBudget;
	const headLineBudget = Math.floor((maxLines * 2) / 3);
	const tailLineBudget = maxLines - headLineBudget;
	const head: string[] = [];
	let size = 0;
	for (const line of lines) {
		if (head.length >= headLineBudget || size + line.length + 1 > headBudget) break;
		head.push(line);
		size += line.length + 1;
	}
	const tail: string[] = [];
	size = 0;
	for (let i = lines.length - 1; i >= head.length; i--) {
		const line = lines[i]!;
		if (tail.length >= tailLineBudget || size + line.length + 1 > tailBudget) break;
		tail.unshift(line);
		size += line.length + 1;
	}
	// One huge line: keep characters instead of lines.
	if (head.length === 0 && tail.length === 0) {
		const start = text.slice(0, headBudget);
		const end = text.slice(text.length - tailBudget);
		const cutChars = text.length - start.length - end.length;
		return { text: `${start}\n\n${marker(cutChars, 0, options.file)}\n\n${end}`, cut: true, cutChars, cutLines: 0 };
	}
	const cutLines = lines.length - head.length - tail.length;
	const cutChars = text.length - head.join("\n").length - tail.join("\n").length;
	return { text: `${head.join("\n")}\n\n${marker(cutChars, cutLines, options.file)}\n\n${tail.join("\n")}`, cut: true, cutChars, cutLines };
}

function marker(chars: number, lines: number, file?: string): string {
	const what = lines > 0 ? `${lines.toLocaleString("en-US")} lines (${chars.toLocaleString("en-US")} characters)` : `${chars.toLocaleString("en-US")} characters`;
	return `[… ${what} cut from the middle${file ? `; the whole output is in ${file}` : ""} …]`;
}
