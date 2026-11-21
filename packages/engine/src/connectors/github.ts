/**
 * GitHub (docs/spec/12 C3) through GitHub's own MCP server. GitHub registers no clients on the spot, so instead of a
 * browser sign-in this uses the GitHub sign-in Piopio already has (docs/spec/05 G4): the GitHub CLI's, or the token in
 * Settings › Git & GitHub.
 */
import { identifyWith } from "./mcp-remote.js";
import type { McpConnector } from "./types.js";

export const github: McpConnector = {
	kind: "mcp",
	id: "github",
	name: "GitHub",
	category: "dev",
	description: "Issues, pull requests, code and repositories, with your GitHub sign-in.",
	setupHelp: "Uses your GitHub sign-in from Settings › Git & GitHub (or the GitHub CLI).",
	mcp: {
		url: "https://api.githubcopilot.com/mcp/",
		signIn: "token",
		prefix: "github",
		labels: { read: "Read repositories, code, issues and pull requests", write: "Create and change issues, pull requests and files", destructive: "Delete and merge" },
		prompt: "Use github_* tools for the user's GitHub repositories, issues and pull requests.",
		core: ["get_me", "search_repositories", "get_file_contents", "search_code", "list_issues", "search_issues", "issue_read", "issue_write", "add_issue_comment", "list_pull_requests", "pull_request_read", "create_pull_request"],
		identify: identifyWith("get_me"),
	},
};
