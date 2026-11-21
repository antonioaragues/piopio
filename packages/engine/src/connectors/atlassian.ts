/**
 * Jira and Confluence (docs/spec/12 C3) through Atlassian's own MCP server: OAuth with dynamic client registration, like
 * Linear. One sign-in covers the Atlassian sites the user picks on the consent page.
 */
import { identifyWith } from "./mcp-remote.js";
import type { McpConnector } from "./types.js";

export const atlassian: McpConnector = {
	kind: "mcp",
	id: "atlassian",
	name: "Jira & Confluence",
	category: "work",
	description: "Find, create and update Jira issues and Confluence pages.",
	setupHelp: "Atlassian signs in through its own server; nothing to set up.",
	mcp: {
		url: "https://mcp.atlassian.com/v1/mcp",
		prefix: "atlassian",
		labels: { read: "Search and read issues and pages", write: "Create and change issues, pages and comments", destructive: "Delete" },
		prompt:
			"Use atlassian_* tools for the user's Jira issues and Confluence pages. Most need the site's cloudId: get it from atlassian_getAccessibleAtlassianResources first.",
		core: [
			"getAccessibleAtlassianResources",
			"atlassianUserInfo",
			"searchJiraIssuesUsingJql",
			"getJiraIssue",
			"createJiraIssue",
			"editJiraIssue",
			"transitionJiraIssue",
			"addCommentToJiraIssue",
			"searchConfluenceUsingCql",
			"getConfluencePage",
		],
		identify: identifyWith("atlassianUserInfo"),
	},
};
