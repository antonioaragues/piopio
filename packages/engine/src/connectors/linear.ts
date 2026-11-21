/**
 * Linear (docs/spec/12 C3) through Linear's own MCP server: OAuth 2.1 with dynamic client registration, so there is no
 * Piopio client to register. One sign-in is one workspace; a second workspace is a second account.
 */
import type { McpConnector } from "./types.js";

/** The first JSON object in a tool's answer, if it has one. */
function parse(text: string): Record<string, unknown> | undefined {
	try {
		const value = JSON.parse(text) as unknown;
		if (value && typeof value === "object") return (Array.isArray(value) ? value[0] : value) as Record<string, unknown>;
	} catch {
		const at = text.indexOf("{");
		if (at >= 0 && at < text.length - 1) return parse(text.slice(at));
	}
	return undefined;
}

const str = (v: unknown) => (typeof v === "string" && v.trim() ? v.trim() : undefined);

export const linear: McpConnector = {
	kind: "mcp",
	id: "linear",
	name: "Linear",
	category: "work",
	description: "Find, create and update your issues, projects and comments.",
	setupHelp: "Linear signs in through its own server; nothing to set up.",
	mcp: {
		url: "https://mcp.linear.app/mcp",
		scope: "read write",
		prefix: "linear",
		labels: { read: "Find and read issues, projects and docs", write: "Create and change issues, projects and comments", destructive: "Delete" },
		prompt: "Use linear_* tools for the user's Linear issues, projects, cycles and comments. Linear's other tools (documents, milestones, attachments, releases, notifications, views…) load with tool_search.",
		// The everyday tools (2026-11-21 Linear offers about 70, ~100 KB of descriptions): issues, comments, projects, teams.
		core: ["list_issues", "get_issue", "save_issue", "list_comments", "save_comment", "list_projects", "get_project", "list_teams", "list_users", "get_user", "list_issue_statuses", "list_issue_labels", "list_cycles"],
		identify: async (call, tools) => {
			const has = (name: string) => tools.some((t) => t.name === name);
			if (!has("get_user")) return undefined;
			const me = await call("get_user", { query: "me" }).catch(() => undefined);
			const user = me && !me.isError ? parse(me.text) : undefined;
			const id = str(user?.id);
			if (!id) return undefined;
			const label = str(user?.email) ?? str(user?.displayName) ?? str(user?.name) ?? "Linear";
			return { id, label };
		},
	},
};
