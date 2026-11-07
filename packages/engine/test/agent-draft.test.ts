import { expect, test } from "vitest";
import { draftAgent, scheduleFrom } from "../src/agent-draft.js";

test("schedules from how people say when, in English and Spanish", () => {
	expect(scheduleFrom("Every morning, tell me what's on my calendar")).toBe("0 8 * * *");
	expect(scheduleFrom("weekdays at 7:30 send me the news")).toBe("30 7 * * 1-5");
	expect(scheduleFrom("every Monday at 9am")).toBe("0 9 * * 1");
	expect(scheduleFrom("on mondays and thursdays at 6 pm")).toBe("0 18 * * 1,4");
	expect(scheduleFrom("cada lunes a las 9")).toBe("0 9 * * 1");
	expect(scheduleFrom("todas las noches a las 22:15")).toBe("15 22 * * *");
	expect(scheduleFrom("todos los días a las 7")).toBe("0 7 * * *");
	expect(scheduleFrom("los fines de semana")).toBe("0 9 * * 0,6");
	expect(scheduleFrom("every hour check the price")).toBe("0 * * * *");
	expect(scheduleFrom("weekly summary")).toBe("0 9 * * 1");
	expect(scheduleFrom("Which tiles go well with oak?")).toBeNull();
	expect(scheduleFrom("at 99 every day")).toBeNull();
});

const lines = [
	{ role: "user" as const, text: "Every morning, check the weather in Valencia and tell me if I need an umbrella." },
	{ role: "assistant" as const, text: "Sure. Today: rain after 3 pm, take one." },
];

test("without a model: the title as the name, the user's words as instructions, the schedule they said", async () => {
	const d = await draftAgent("Umbrella check", lines);
	expect(d).toEqual({ name: "Umbrella check", instructions: "Do what was asked in the conversation “Umbrella check”:\n\n- Every morning, check the weather in Valencia and tell me if I need an umbrella.", schedule: "0 8 * * *" });
});

test("with a model: its name and instructions; its schedule only when it's a valid cron, else the user's words", async () => {
	const reply = (schedule: unknown) => async () => `Here: ${JSON.stringify({ name: "Weather watch", instructions: "Check Valencia's forecast. Tell me if rain is likely.", schedule })}`;
	expect(await draftAgent("Umbrella check", lines, reply("30 7 * * 1-5"))).toEqual({ name: "Weather watch", instructions: "Check Valencia's forecast. Tell me if rain is likely.", schedule: "30 7 * * 1-5" });
	expect((await draftAgent("Umbrella check", lines, reply("every morning"))).schedule).toBe("0 8 * * *");
	expect((await draftAgent("Umbrella check", lines, reply(null))).schedule).toBe("0 8 * * *");
	// A model that fails or answers nonsense: the plain draft.
	expect((await draftAgent("Umbrella check", lines, async () => "no json")).name).toBe("Umbrella check");
	expect((await draftAgent("Umbrella check", lines, async () => { throw new Error("down"); })).name).toBe("Umbrella check");
});

test("without a model, the name leaves out the schedule phrase", async () => {
	const d = await draftAgent("Every weekday at 7:30, check the weather in Valencia", [{ role: "user", text: "Every weekday at 7:30, check the weather in Valencia" }]);
	expect(d.name).toBe("Check the weather in");
	expect(d.schedule).toBe("30 7 * * 1-5");
	expect((await draftAgent("Plan my week.", [])).name).toBe("Plan my week");
});
