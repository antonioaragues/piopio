import { expect, test } from "vitest";
import { contactFor, type Contact } from "../src/agents/definition.js";

// Models write names; definitions keep ids (docs/spec/27 A3: “Lucía” failed after it was approved).
test("a contact by id, by name in any case and accents, or by a first name only one has", () => {
	const contacts: Contact[] = [
		{ id: "owner", name: "Toño", role: "owner" },
		{ id: "lucia", name: "Lucía", role: "contact" },
		{ id: "ana-g", name: "Ana García", role: "contact" },
		{ id: "ana-p", name: "Ana Pérez", role: "contact" },
	];
	expect(contactFor(contacts, "lucia")?.id).toBe("lucia");
	expect(contactFor(contacts, "Lucía")?.id).toBe("lucia");
	expect(contactFor(contacts, "@LUCIA")?.id).toBe("lucia");
	expect(contactFor(contacts, "Tono")?.id).toBe("owner");
	expect(contactFor(contacts, "ana garcia")?.id).toBe("ana-g");
	expect(contactFor(contacts, "Ana")).toBeUndefined();
	expect(contactFor(contacts, "Marta")).toBeUndefined();
});
