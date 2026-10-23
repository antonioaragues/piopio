/**
 * What each connector may do (docs/spec/12-connectors, Settings › Connectors c2/c4): tools grouped into capabilities
 * the user reads ("Create and change events"), each set to Runs, Asks first or Off. Safe defaults: reading runs,
 * changes ask, deleting is off. Sending (mail, invitations) and deleting never run without asking.
 */
export type Access = "read" | "write" | "send" | "destructive";
export type Permission = "runs" | "ask" | "off";

export type CapabilityGroup = {
	id: string;
	capability: "calendar" | "mail";
	label: string;
	tools: string[];
	/** The kind of action, which sets the default and the choices. */
	access: Access;
	/** Fine print under the tool ids. */
	note?: string;
};

export const CAPABILITIES: CapabilityGroup[] = [
	{ id: "calendar.read", capability: "calendar", label: "Read events and find free time", tools: ["calendar_events", "calendar_free_time"], access: "read" },
	{ id: "calendar.write", capability: "calendar", label: "Create and change events", tools: ["calendar_create_event", "calendar_update_event"], access: "write", note: "Invitations always ask" },
	{ id: "calendar.delete", capability: "calendar", label: "Delete events", tools: ["calendar_delete_event"], access: "destructive" },
	{ id: "mail.read", capability: "mail", label: "Search and read mail", tools: ["mail_search", "mail_read"], access: "read" },
	{ id: "mail.draft", capability: "mail", label: "Write drafts", tools: ["mail_draft"], access: "write" },
	{ id: "mail.send", capability: "mail", label: "Send mail", tools: ["mail_send"], access: "send" },
];

export const defaultPermission = (access: Access): Permission => (access === "read" ? "runs" : access === "destructive" ? "off" : "ask");

/** The choices an action offers: sending and deleting can't run on their own. */
export const choices = (access: Access): Permission[] => (access === "send" || access === "destructive" ? ["ask", "off"] : ["runs", "ask", "off"]);

export const groupOf = (tool: string) => CAPABILITIES.find((g) => g.tools.includes(tool));

/** A permission as it applies to one call: a send (an invitation, an email) asks even where its group runs. */
export function effective(permission: Permission, access: Access): Permission {
	if (permission === "runs" && (access === "send" || access === "destructive")) return "ask";
	return permission;
}
