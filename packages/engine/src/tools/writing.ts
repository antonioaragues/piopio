/**
 * How answers are written in chats, notebooks and agents (feedback 2026-10-26): no em dashes, and comparisons as
 * Markdown tables, which the app draws as real tables (a table drawn with spaces in a code block wraps into a mess).
 */
import { defineExtension, section } from "@earendil-works/pi-durable";

export const WRITING_EXTENSION = "piopio-writing";

const WRITING = `Writing style:
- Never use em dashes (—) or en dashes (–) as punctuation. Use a comma, a colon, parentheses, or a new sentence instead.
- For a comparison of several things across several dimensions, use a Markdown table (| … | … |). Never draw a table with spaces or box characters inside a code block; keep code blocks for code.`;

export function writingExtension() {
	return defineExtension({ name: WRITING_EXTENSION, sections: [section("writing", () => WRITING)] });
}
