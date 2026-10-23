/** Outlook calendar and mail through Microsoft Graph (docs/spec/12-connectors C1). Personal and work accounts. */
import type { AuthorizedFetch, Calendar, CalendarEvent, ConnectorDefinition, EventInput, Mailbox, MailMessage } from "./types.js";

type GEvent = {
	id: string;
	subject?: string;
	bodyPreview?: string;
	webLink?: string;
	isAllDay?: boolean;
	start?: { dateTime: string; timeZone: string };
	end?: { dateTime: string; timeZone: string };
	location?: { displayName?: string };
	attendees?: { emailAddress?: { name?: string; address?: string } }[];
	organizer?: { emailAddress?: { name?: string; address?: string } };
	calendar?: { name?: string };
};

type GMessage = {
	id: string;
	subject?: string;
	bodyPreview?: string;
	receivedDateTime?: string;
	isDraft?: boolean;
	from?: { emailAddress?: { name?: string; address?: string } };
	toRecipients?: { emailAddress?: { name?: string; address?: string } }[];
	body?: { content?: string };
};

async function json<T>(response: Response, what: string): Promise<T> {
	if (!response.ok) throw new Error(`Outlook couldn't ${what} (${response.status}): ${(await response.text()).slice(0, 200)}`);
	return (await response.json()) as T;
}

const zone = () => Intl.DateTimeFormat().resolvedOptions().timeZone;
const person = (p?: { emailAddress?: { name?: string; address?: string } }) => p?.emailAddress?.name || p?.emailAddress?.address || "";

/** Graph returns local times without an offset in the zone we ask for; give them the offset back. */
function withOffset(local: string): string {
	if (/[zZ]|[+-]\d\d:\d\d$/.test(local)) return local;
	const at = new Date(`${local.slice(0, 19)}Z`);
	const asLocal = new Date(at.toLocaleString("en-US", { timeZone: zone() }));
	const asUtc = new Date(at.toLocaleString("en-US", { timeZone: "UTC" }));
	const minutes = Math.round((asLocal.getTime() - asUtc.getTime()) / 60_000);
	const sign = minutes >= 0 ? "+" : "-";
	const abs = Math.abs(minutes);
	return `${local.slice(0, 19)}${sign}${String(Math.floor(abs / 60)).padStart(2, "0")}:${String(abs % 60).padStart(2, "0")}`;
}

function toEvent(e: GEvent): CalendarEvent {
	return {
		id: e.id,
		calendar: e.calendar?.name ?? "Calendar",
		title: e.subject ?? "(no title)",
		start: e.start ? (e.isAllDay ? e.start.dateTime.slice(0, 10) : withOffset(e.start.dateTime)) : "",
		end: e.end ? (e.isAllDay ? e.end.dateTime.slice(0, 10) : withOffset(e.end.dateTime)) : "",
		allDay: Boolean(e.isAllDay),
		...(e.location?.displayName ? { location: e.location.displayName } : {}),
		...(e.attendees?.length ? { attendees: e.attendees.map(person).filter(Boolean) } : {}),
		...(e.organizer ? { organizer: person(e.organizer) } : {}),
		...(e.webLink ? { link: e.webLink } : {}),
		...(e.bodyPreview ? { description: e.bodyPreview.slice(0, 500) } : {}),
	};
}

function toBody(input: Partial<EventInput>) {
	const time = (v: string) => ({ dateTime: input.allDay ? `${v.slice(0, 10)}T00:00:00` : new Date(v).toISOString().slice(0, 19), timeZone: input.allDay ? zone() : "UTC" });
	return {
		...(input.title !== undefined ? { subject: input.title } : {}),
		...(input.start !== undefined ? { start: time(input.start) } : {}),
		...(input.end !== undefined ? { end: time(input.end) } : {}),
		...(input.allDay !== undefined ? { isAllDay: input.allDay } : {}),
		...(input.location !== undefined ? { location: { displayName: input.location } } : {}),
		...(input.description !== undefined ? { body: { contentType: "text", content: input.description } } : {}),
		...(input.attendees ? { attendees: input.attendees.map((address) => ({ emailAddress: { address }, type: "required" })) } : {}),
	};
}

const prefer = () => ({ Prefer: `outlook.timezone="${zone()}"` });

function calendar(fetch: AuthorizedFetch): Calendar {
	const select = "$select=id,subject,bodyPreview,webLink,isAllDay,start,end,location,attendees,organizer";
	return {
		async calendars() {
			const data = await json<{ value?: { id: string; name?: string; isDefaultCalendar?: boolean }[] }>(await fetch("/v1.0/me/calendars"), "list your calendars");
			return (data.value ?? []).map((c) => ({ id: c.id, name: c.name ?? "Calendar", primary: Boolean(c.isDefaultCalendar) }));
		},
		async events({ from, to, query }) {
			const params = new URLSearchParams({ startDateTime: from, endDateTime: to, $top: "100", $orderby: "start/dateTime" });
			const data = await json<{ value?: GEvent[] }>(await fetch(`/v1.0/me/calendarView?${params}&${select}`, { headers: prefer() }), "read events");
			const events = (data.value ?? []).map(toEvent);
			if (!query) return events;
			const q = query.toLowerCase();
			return events.filter((e) => [e.title, e.location, e.description, ...(e.attendees ?? [])].some((v) => v?.toLowerCase().includes(q)));
		},
		async get(id) {
			return toEvent(await json<GEvent>(await fetch(`/v1.0/me/events/${encodeURIComponent(id)}?${select}`, { headers: prefer() }), "read the event"));
		},
		async create(input) {
			const path = input.calendar ? `/v1.0/me/calendars/${encodeURIComponent(input.calendar)}/events` : "/v1.0/me/events";
			return toEvent(await json<GEvent>(await fetch(path, { method: "POST", headers: { "content-type": "application/json", ...prefer() }, body: JSON.stringify(toBody(input)) }), "create the event"));
		},
		async update(id, patch) {
			return toEvent(await json<GEvent>(await fetch(`/v1.0/me/events/${encodeURIComponent(id)}`, { method: "PATCH", headers: { "content-type": "application/json", ...prefer() }, body: JSON.stringify(toBody(patch)) }), "change the event"));
		},
		async remove(id) {
			const response = await fetch(`/v1.0/me/events/${encodeURIComponent(id)}`, { method: "DELETE" });
			if (!response.ok && response.status !== 404) throw new Error(`Outlook couldn't delete the event (${response.status}).`);
		},
	};
}

function toMessage(m: GMessage, withBody = false): MailMessage {
	return {
		id: m.id,
		subject: m.subject ?? "(no subject)",
		from: person(m.from),
		to: (m.toRecipients ?? []).map(person).filter(Boolean),
		received: m.receivedDateTime ?? "",
		preview: (m.bodyPreview ?? "").slice(0, 300),
		...(withBody && m.body?.content ? { body: m.body.content.slice(0, 20_000) } : {}),
		...(m.isDraft ? { isDraft: true } : {}),
	};
}

function mailbox(fetch: AuthorizedFetch): Mailbox {
	const select = "$select=id,subject,bodyPreview,receivedDateTime,isDraft,from,toRecipients";
	return {
		async search(query, limit) {
			const params = query.trim() ? `$search=${encodeURIComponent(`"${query.replaceAll('"', "")}"`)}&$top=${limit}` : `$top=${limit}&$orderby=receivedDateTime desc`;
			const data = await json<{ value?: GMessage[] }>(await fetch(`/v1.0/me/messages?${params}&${select}`), "search your mail");
			return (data.value ?? []).map((m) => toMessage(m));
		},
		async read(id) {
			return toMessage(await json<GMessage>(await fetch(`/v1.0/me/messages/${encodeURIComponent(id)}?${select},body`, { headers: { Prefer: 'outlook.body-content-type="text"' } }), "read the message"), true);
		},
		async draft({ to, subject, body, cc }) {
			const recipients = (list: string[]) => list.map((address) => ({ emailAddress: { address } }));
			const created = await json<GMessage>(
				await fetch("/v1.0/me/messages", { method: "POST", headers: { "content-type": "application/json" }, body: JSON.stringify({ subject, body: { contentType: "text", content: body }, toRecipients: recipients(to), ...(cc?.length ? { ccRecipients: recipients(cc) } : {}) }) }),
				"save the draft",
			);
			return toMessage({ ...created, isDraft: true });
		},
		async send(id) {
			const response = await fetch(`/v1.0/me/messages/${encodeURIComponent(id)}/send`, { method: "POST" });
			if (!response.ok) throw new Error(`Outlook couldn't send the draft (${response.status}).`);
		},
	};
}

export const outlook: ConnectorDefinition = {
	id: "outlook",
	name: "Outlook",
	category: "calendar",
	description: "Your Outlook calendar and mail: read events and messages, create events, write drafts.",
	oauth: {
		authorizeUrl: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize",
		tokenUrl: "https://login.microsoftonline.com/common/oauth2/v2.0/token",
		scopes: ["openid", "email", "offline_access", "User.Read", "Calendars.ReadWrite", "Mail.ReadWrite", "Mail.Send"],
		loopbackHost: "localhost",
		needsSecret: false,
	},
	apiBase: "https://graph.microsoft.com",
	async identify(fetch) {
		const me = await json<{ id?: string; mail?: string; userPrincipalName?: string }>(await fetch("/v1.0/me?$select=id,mail,userPrincipalName"), "read who signed in");
		return { id: me.id ?? "outlook", label: me.mail ?? me.userPrincipalName ?? "Outlook account" };
	},
	calendar,
	mailbox,
	setupHelp: "Register an app in Microsoft Entra (“Accounts in any organizational directory and personal Microsoft accounts”), add the “Mobile and desktop applications” platform with redirect http://localhost, then paste its application (client) ID.",
};
