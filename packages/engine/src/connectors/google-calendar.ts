/** Google Calendar through the Calendar API v3 (docs/spec/12-connectors C1). */
import type { AuthorizedFetch, Calendar, CalendarEvent, ConnectorDefinition, EventInput } from "./types.js";

type GEvent = {
	id: string;
	summary?: string;
	description?: string;
	location?: string;
	htmlLink?: string;
	start?: { dateTime?: string; date?: string };
	end?: { dateTime?: string; date?: string };
	attendees?: { email?: string; displayName?: string }[];
	organizer?: { email?: string; displayName?: string };
};

async function json<T>(response: Response, what: string): Promise<T> {
	if (!response.ok) throw new Error(`Google Calendar couldn't ${what} (${response.status}): ${(await response.text()).slice(0, 200)}`);
	return (await response.json()) as T;
}

/** Event ids carry their calendar so updates find it: `<calendarId>|<eventId>`. */
const eventId = (calendar: string, id: string) => `${calendar}|${id}`;
const split = (id: string) => {
	const at = id.lastIndexOf("|");
	return at < 0 ? { calendar: "primary", id } : { calendar: id.slice(0, at), id: id.slice(at + 1) };
};

function toEvent(e: GEvent, calendar: string, calendarName: string): CalendarEvent {
	const allDay = Boolean(e.start?.date && !e.start?.dateTime);
	return {
		id: eventId(calendar, e.id),
		calendar: calendarName,
		title: e.summary ?? "(no title)",
		start: e.start?.dateTime ?? e.start?.date ?? "",
		end: e.end?.dateTime ?? e.end?.date ?? "",
		allDay,
		...(e.location ? { location: e.location } : {}),
		...(e.attendees?.length ? { attendees: e.attendees.map((a) => a.displayName ?? a.email ?? "").filter(Boolean) } : {}),
		...(e.organizer ? { organizer: e.organizer.displayName ?? e.organizer.email ?? "" } : {}),
		...(e.htmlLink ? { link: e.htmlLink } : {}),
		...(e.description ? { description: e.description.slice(0, 500) } : {}),
	};
}

function toBody(input: Partial<EventInput>) {
	const time = (v: string) => (input.allDay ? { date: v.slice(0, 10) } : { dateTime: v });
	return {
		...(input.title !== undefined ? { summary: input.title } : {}),
		...(input.start !== undefined ? { start: time(input.start) } : {}),
		...(input.end !== undefined ? { end: time(input.end) } : {}),
		...(input.location !== undefined ? { location: input.location } : {}),
		...(input.description !== undefined ? { description: input.description } : {}),
		...(input.attendees ? { attendees: input.attendees.map((email) => ({ email })) } : {}),
	};
}

function calendar(fetch: AuthorizedFetch): Calendar {
	let names: Map<string, string> | undefined;
	const list = async () => {
		const data = await json<{ items?: { id: string; summary?: string; summaryOverride?: string; primary?: boolean; selected?: boolean; backgroundColor?: string }[] }>(await fetch("/calendar/v3/users/me/calendarList"), "list your calendars");
		const items = (data.items ?? []).map((c) => ({ id: c.id, name: c.summaryOverride ?? c.summary ?? c.id, primary: Boolean(c.primary), shown: c.selected !== false || Boolean(c.primary), ...(c.backgroundColor ? { color: c.backgroundColor } : {}) }));
		names = new Map(items.map((c) => [c.id, c.name]));
		return items;
	};
	const nameOf = async (id: string) => (names ?? new Map((await list()).map((c) => [c.id, c.name]))).get(id) ?? id;
	return {
		async calendars() {
			return list();
		},
		async events({ from, to, query, include }) {
			const calendars = (await list()).filter((c) => (include ? include(c.id, c.shown) : c.shown));
			const all = await Promise.all(
				calendars.map(async (c) => {
					const params = new URLSearchParams({ timeMin: from, timeMax: to, singleEvents: "true", orderBy: "startTime", maxResults: "100", ...(query ? { q: query } : {}) });
					const data = await json<{ items?: GEvent[] }>(await fetch(`/calendar/v3/calendars/${encodeURIComponent(c.id)}/events?${params}`), "read events");
					return (data.items ?? []).map((e) => toEvent(e, c.id, c.name));
				}),
			);
			return all.flat();
		},
		async get(id) {
			const { calendar: cal, id: raw } = split(id);
			return toEvent(await json<GEvent>(await fetch(`/calendar/v3/calendars/${encodeURIComponent(cal)}/events/${encodeURIComponent(raw)}`), "read the event"), cal, await nameOf(cal));
		},
		async create(input) {
			const cal = input.calendar ?? "primary";
			const created = await json<GEvent>(await fetch(`/calendar/v3/calendars/${encodeURIComponent(cal)}/events`, { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify(toBody(input)) }), "create the event");
			return toEvent(created, cal, await nameOf(cal));
		},
		async update(id, patch) {
			const { calendar: cal, id: raw } = split(id);
			const updated = await json<GEvent>(await fetch(`/calendar/v3/calendars/${encodeURIComponent(cal)}/events/${encodeURIComponent(raw)}`, { method: "PATCH", headers: { "content-type": "application/json" }, body: JSON.stringify(toBody(patch)) }), "change the event");
			return toEvent(updated, cal, await nameOf(cal));
		},
		async remove(id) {
			const { calendar: cal, id: raw } = split(id);
			const response = await fetch(`/calendar/v3/calendars/${encodeURIComponent(cal)}/events/${encodeURIComponent(raw)}`, { method: "DELETE" });
			if (!response.ok && response.status !== 410) throw new Error(`Google Calendar couldn't delete the event (${response.status}).`);
		},
	};
}

export const googleCalendar: ConnectorDefinition = {
	id: "google-calendar",
	name: "Google Calendar",
	category: "calendar",
	description: "Read your calendars, find free time, and create or change events.",
	oauth: {
		authorizeUrl: "https://accounts.google.com/o/oauth2/v2/auth",
		tokenUrl: "https://oauth2.googleapis.com/token",
		scopes: ["openid", "email", "https://www.googleapis.com/auth/calendar.readonly", "https://www.googleapis.com/auth/calendar.events"],
		extraParams: { access_type: "offline", prompt: "consent" },
		loopbackHost: "127.0.0.1",
		needsSecret: true,
	},
	apiBase: "https://www.googleapis.com",
	async identify(fetch) {
		const me = await json<{ sub?: string; email?: string }>(await fetch("/oauth2/v3/userinfo"), "read who signed in");
		return { id: me.sub ?? me.email ?? "google", label: me.email ?? "Google account" };
	},
	calendar,
	setupHelp: "Create an OAuth client of type “Desktop app” in a Google Cloud project with the Google Calendar API enabled, then paste its client ID and secret.",
};
