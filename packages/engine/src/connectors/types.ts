/**
 * Connectors (docs/spec/12-connectors): apps you connect once — Google Calendar, Outlook — whose data any chat,
 * notebook, Build session or agent can use. A connector says how to sign in and what it can do; the tools come
 * from capabilities (a calendar, a mailbox) that several connectors implement, so "check my calendar" reads every
 * connected calendar in one call.
 */

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

export type ConnectorDefinition = {
	id: string;
	name: string;
	/** For the app's tile. */
	category: "calendar" | "email";
	description: string;
	oauth: OAuthConfig;
	/** Where its API lives (overridable in tests). */
	apiBase: string;
	/** Who signed in: shown on the account ("antonio@gmail.com"). */
	identify(fetch: AuthorizedFetch): Promise<{ id: string; label: string }>;
	calendar?(fetch: AuthorizedFetch): Calendar;
	mailbox?(fetch: AuthorizedFetch): Mailbox;
	/** Shown when no OAuth client is set up yet. */
	setupHelp: string;
};

/** Where a connector's endpoints live; tests point them at a fake server. */
export type ConnectorEndpoints = Partial<Record<string, { authorizeUrl?: string; tokenUrl?: string; apiBase?: string }>>;
