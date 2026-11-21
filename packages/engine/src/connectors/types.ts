/**
 * Connectors (docs/spec/12-connectors): apps you connect once — Google Calendar, Outlook — whose data any chat,
 * Build session or agent can use. A connector says how to sign in and what it can do; the tools come
 * from capabilities (a calendar, a mailbox) that several connectors implement, so "check my calendar" reads every
 * connected calendar in one call.
 */
import type { Access } from "./permissions.js";

/** OAuth 2.0 with PKCE through the browser and a loopback redirect (RFC 8252). */
export type OAuthConfig = {
	authorizeUrl: string;
	tokenUrl: string;
	scopes: string[];
	/** Extra authorize parameters (Google: offline access and consent for a refresh token). */
	extraParams?: Record<string, string>;
	/** "127.0.0.1" (Google) or "localhost" (Microsoft) in the redirect URI. */
	loopbackHost: "127.0.0.1" | "localhost";
	/** Google's desktop clients also send their (non-confidential) secret. */
	needsSecret: boolean;
};

/** A connected account's tokens, kept in the Keychain. */
export type Tokens = { access: string; refresh?: string; expires: number };

/** Something a connector can be: a calendar, a mailbox. */
export type CalendarEvent = {
	id: string;
	calendar: string;
	title: string;
	start: string;
	end: string;
	allDay: boolean;
	location?: string;
	attendees?: string[];
	organizer?: string;
	link?: string;
	description?: string;
};

export type EventInput = { title: string; start: string; end: string; calendar?: string; location?: string; description?: string; attendees?: string[]; allDay?: boolean };

/** One of an account's calendars; `shown` is whether the app itself shows it (Google's selection, Outlook's default). */
export type CalendarEntry = { id: string; name: string; primary: boolean; color?: string; shown: boolean };

export interface Calendar {
	calendars(): Promise<CalendarEntry[]>;
	/** `include` picks the calendars to read (Settings › Connectors); without it, the ones the app shows. */
	events(range: { from: string; to: string; query?: string; include?: (calendarId: string, shown: boolean) => boolean }): Promise<CalendarEvent[]>;
	create(input: EventInput): Promise<CalendarEvent>;
	update(id: string, patch: Partial<EventInput>): Promise<CalendarEvent>;
	remove(id: string): Promise<void>;
	get(id: string): Promise<CalendarEvent>;
}

export type MailMessage = { id: string; subject: string; from: string; to: string[]; received: string; preview: string; body?: string; isDraft?: boolean };

export interface Mailbox {
	search(query: string, limit: number): Promise<MailMessage[]>;
	read(id: string): Promise<MailMessage>;
	draft(input: { to: string[]; subject: string; body: string; cc?: string[] }): Promise<MailMessage>;
	send(id: string): Promise<void>;
}

/** An authorized fetch for one account: adds the token, refreshes it when it expires. */
export type AuthorizedFetch = (path: string, init?: RequestInit) => Promise<Response>;

type ConnectorBase = {
	id: string;
	name: string;
	/** For the app's tile and the catalog's sections. */
	category: "calendar" | "email" | "work" | "files" | "dev";
	description: string;
	/** Shown when no OAuth client is set up yet. */
	setupHelp: string;
};

/** An app Piopio talks to through its API (Google Calendar, Outlook): our own OAuth client, our own tools. */
export type ApiConnector = ConnectorBase & {
	kind?: "api";
	oauth: OAuthConfig;
	/** Where its API lives (overridable in tests). */
	apiBase: string;
	/** Who signed in: shown on the account ("antonio@gmail.com"). */
	identify(fetch: AuthorizedFetch): Promise<{ id: string; label: string }>;
	calendar?(fetch: AuthorizedFetch): Calendar;
	mailbox?(fetch: AuthorizedFetch): Mailbox;
};

/** A tool the app's MCP server offers, as Piopio keeps it (connectors.json) so conversations get it without asking the server. */
export type McpToolInfo = {
	/** Its name on the server. */
	name: string;
	title?: string;
	description: string;
	inputSchema: Record<string, unknown>;
	access: Access;
};

/** Calls one of the account's MCP tools; resolves to the text the model reads. */
export type McpCall = (tool: string, args: Record<string, unknown>) => Promise<{ text: string; isError: boolean }>;

/**
 * An app whose tools come from its own MCP server (docs/spec/12 §4): Piopio signs in through the server's OAuth
 * (discovery and dynamic client registration, no client of ours to register) and passes the server's tools on, each
 * marked reading, changing or deleting so changes ask first.
 */
export type McpConnector = ConnectorBase & {
	kind: "mcp";
	mcp: {
		url: string;
		/**
		 * How it signs in: its server's OAuth through the browser (default), or a token Piopio already has for the app
		 * (GitHub: the GitHub CLI's sign-in or the token in Settings › Git & GitHub), with no browser step.
		 */
		signIn?: "oauth" | "token";
		/** Scopes to ask for (Linear: "read write"). */
		scope?: string;
		/** Prefix of the tools' names in conversations ("linear" → linear_list_issues). */
		prefix: string;
		/** Settings' labels for its reading, changing and deleting tools. */
		labels: { read: string; write: string; destructive: string };
		/** One line for the prompt: what the tools are for. */
		prompt: string;
		/**
		 * Tools offered up front, by server name; the others wait until the model finds them with tool search. Without it,
		 * all are offered up front when there are few (DIRECT_LIMIT), else all wait for tool search.
		 */
		core?: string[];
		/** Tools whose kind the server doesn't say right: by server name. */
		access?: Record<string, Access>;
		/** Who signed in, through its own tools; without it, one account. */
		identify?(call: McpCall, tools: McpToolInfo[]): Promise<{ id: string; label: string } | undefined>;
	};
};

export type ConnectorDefinition = ApiConnector | McpConnector;

export const isMcp = (d: ConnectorDefinition): d is McpConnector => d.kind === "mcp";

/** Where a connector's endpoints live; tests point them at a fake server. */
export type ConnectorEndpoints = Partial<Record<string, { authorizeUrl?: string; tokenUrl?: string; apiBase?: string; mcpUrl?: string }>>;
