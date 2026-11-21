/**
 * Notion (docs/spec/12 C3) through Notion's own MCP server: OAuth with dynamic client registration, like Linear. One
 * sign-in is one workspace, with the pages you let Piopio see on Notion's consent page.
 */
import { identifyWith } from "./mcp-remote.js";
import type { McpConnector } from "./types.js";

export const notion: McpConnector = {
	kind: "mcp",
	id: "notion",
	name: "Notion",
	category: "files",
	description: "Search, read and write your pages and databases.",
	setupHelp: "Notion signs in through its own server; nothing to set up.",
	mcp: {
		url: "https://mcp.notion.com/mcp",
		prefix: "notion",
		labels: { read: "Search and read pages and databases", write: "Create and edit pages, databases and comments", destructive: "Delete" },
		prompt: "Use notion_* tools for the user's Notion pages and databases: notion_search to find them, notion_fetch to read one.",
		// Notion's tools are notion-search, notion-fetch…: Piopio names them notion_search, notion_fetch.
		core: ["notion-search", "notion-fetch", "notion-create-pages", "notion-update-page", "notion-get-comments", "notion-create-comment"],
		identify: identifyWith("notion-get-self"),
	},
};
