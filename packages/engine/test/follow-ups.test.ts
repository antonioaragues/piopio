import { expect, test } from "vitest";
import { FOLLOW_UPS_PROMPT, parseFollowUps } from "../src/sessions.js";

test("Ask next: suggestions only when the answer calls for a reply; [] means none", () => {
	expect(FOLLOW_UPS_PROMPT).toContain("[] for none");
	expect(FOLLOW_UPS_PROMPT).toContain("a finished task");
	expect(parseFollowUps("[]")).toEqual([]);
	expect(parseFollowUps('["Sí, arréglalo", " ", "No", "Más", "Cuatro"]')).toEqual(["Sí, arréglalo", "No", "Más"]);
	expect(parseFollowUps("not json")).toBeUndefined();
	expect(parseFollowUps('{"a":1}')).toBeUndefined();
});
