/** Sentry (docs/spec/12 C3) through Sentry's own MCP server: OAuth with dynamic client registration, like Linear. */
import { identifyWith } from "./mcp-remote.js";
import type { McpConnector } from "./types.js";

export const sentry: McpConnector = {
	kind: "mcp",
	id: "sentry",
	name: "Sentry",
	category: "dev",
	description: "Find errors and issues in your projects, and see what caused them.",
	setupHelp: "Sentry signs in through its own server; nothing to set up.",
	mcp: {
		url: "https://mcp.sentry.dev/mcp",
		prefix: "sentry",
		labels: { read: "Find issues, errors and events", write: "Update issues and run analyses", destructive: "Delete" },
		prompt: "Use sentry_* tools for the user's Sentry errors, issues and events.",
		core: ["whoami", "find_organizations", "find_projects", "search_issues", "get_issue_details", "search_events", "update_issue"],
		identify: identifyWith("whoami"),
	},
};
