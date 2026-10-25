#!/usr/bin/env node
// Memory test set M0 (docs/spec/14-memory §5.5): six months of Alex talking with their assistant Kit (about 2,000
// messages), with facts that change several times (city, job, pets, diet, a wedding date), decoys that share words
// with the questions, and paraphrased questions about the end state, the past, events and things never said.
//
//   node packages/engine/test/memory-eval/build-set.mjs     → memory-2000.json next to this file
//
// Deterministic: the same seed writes the same file. The facts are written by hand below; the filler around them is
// drawn from templates.
import { writeFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

let seed = 20261025;
const rand = () => {
	seed |= 0;
	seed = (seed + 0x6d2b79f5) | 0;
	let t = Math.imul(seed ^ (seed >>> 15), 1 | seed);
	t = (t + Math.imul(t ^ (t >>> 7), 61 | t)) ^ t;
	return ((t ^ (t >>> 14)) >>> 0) / 4294967296;
};
const pick = (a) => a[Math.floor(rand() * a.length)];

const START = Date.parse("2026-04-01T08:00:00Z");
const DAYS = 183; // to 30 September
const day = (iso) => Math.round((Date.parse(`${iso}T00:00:00Z`) - Date.parse("2026-04-01T00:00:00Z")) / 86_400_000);

/** The facts, on their day: what Alex says, and what Kit answers. */
const FACTS = [
	["2026-04-02", "Quick intro so you know me: I'm Alex, I'm a nurse at Hospital La Fe and I've lived in Valencia for nine years.", "Nice to meet you, Alex. I'll keep that in mind."],
	["2026-04-02", "Also, please keep your answers short. I read them between shifts.", "Understood: short answers from now on."],
	["2026-04-03", "Our flat is tiny but I love being five minutes from the Turia gardens.", "Sounds like a great spot."],
	["2026-04-04", "Right now I'm on night shifts, four nights a week.", "That's tough. I'll keep reminders away from your sleeping hours."],
	["2026-04-06", "I've been vegetarian for six years, so skip any meat recipes please.", "Noted, vegetarian recipes only."],
	["2026-04-08", "Important: I'm allergic to cashews. Badly.", "Got it. I'll flag cashews in anything I suggest."],
	["2026-04-09", "My partner Sam works as a sound engineer, mostly theatre gigs.", "Good to know about Sam."],
	["2026-04-10", "The landlord doesn't allow animals, which is sad because I've always wanted a dog.", "Maybe one day with another flat."],
	["2026-04-12", "My sister Lucía is getting married on October 3rd in Seville!", "Congratulations to Lucía! I'll remember the date."],
	["2026-04-15", "I signed up for the Valencia 10K on May 10.", "Good luck with the training."],
	["2026-04-20", "I still drive the old Seat Ibiza, it's 14 years old.", "Old but reliable, I hope."],
	["2026-05-03", "Started reading Piranesi last night, it's strange and lovely.", "Enjoy it."],
	["2026-05-10", "Did the 10K this morning: 52:30. Personal best!", "Congratulations on the personal best!"],
	["2026-05-20", "Big news: Sam got a job offer in Madrid and we signed for a flat there. We move on June 15.", "That's a big change. Want help planning the move?"],
	["2026-06-01", "I accepted a job at Hospital Gregorio Marañón. Still nursing, but in pediatrics, and day shifts only.", "Day shifts! That should help a lot."],
	["2026-06-08", "Sold the Ibiza to our neighbour for 2,800 euros. No car in Madrid.", "Fair price for its age."],
	["2026-06-16", "First night in the new flat in Chamberí. Boxes everywhere.", "Welcome home. Take it one box at a time."],
	["2026-06-21", "Housewarming tonight. I'm making a big mushroom paella for twelve people.", "Ambitious! Have fun."],
	["2026-06-25", "Lucía's venue flooded, so the wedding moved to November 7th. Same city.", "What a scare. I'll update the date."],
	["2026-06-30", "Finished Piranesi. Started The Overstory today, it's huge.", "Big book. Enjoy."],
	["2026-07-02", "We adopted a puppy! Her name is Toffee, she's a beagle mix. The new landlord is fine with pets.", "Welcome, Toffee!"],
	["2026-07-05", "Signed up for the Madrid half marathon on September 27.", "That's a big step up from the 10K."],
	["2026-07-09", "Bought an e-bike, an Orbea. I'll commute to the hospital on it.", "Good for the commute and the legs."],
	["2026-07-14", "Found my coffee place: Hola Coffee in Lavapiés. The flat white is perfect.", "Noted as your favourite café."],
	["2026-07-20", "My doctor says my iron is low, so I've started eating fish again. Pescatarian now, I guess.", "Makes sense. I'll include fish in suggestions."],
	["2026-07-30", "Sam's birthday is August 14. I want to give him a vintage film camera.", "Lovely idea. I'll remind you early in August."],
	["2026-08-05", "Mum's knee surgery went well, she's already walking with crutches.", "Glad to hear it went well."],
	["2026-08-16", "Off to Asturias for a week, staying in Cangas de Onís.", "Enjoy the mountains."],
	["2026-08-28", "Sam's company is transferring him to Lisbon from October. We'll rent near Alfama. Moving again!", "Another move. I can help with the plan."],
	["2026-09-01", "I'll start Portuguese lessons with a tutor called Inês, Tuesday evenings.", "Boa sorte!"],
	["2026-09-10", "Toffee has a little brother now: a rescued greyhound called Pico.", "Two dogs! Congratulations."],
	["2026-09-18", "I've been promoted to charge nurse on the pediatric ward.", "Congratulations, that's well deserved."],
	["2026-09-27", "Finished the Madrid half in 1:58:41!", "Under two hours, well done!"],
];

/** Things around the facts that share their words, so a keyword match isn't enough. */
const DECOYS = [
	["2026-04-14", "My cousin in Lisbon sent photos of the trams, I'm so jealous.", "Lisbon is beautiful in spring."],
	["2026-04-22", "Marta from work lives in Getafe, near Madrid. She says the summers are brutal.", "Good to know before visiting."],
	["2026-05-05", "My friend Jorge just moved to Bilbao for work.", "Hope he settles in well."],
	["2026-05-14", "Sam's sister has two cats, Mochi and Pixel.", "Cute names."],
	["2026-05-25", "There's a vegetarian place in Valencia called La Tastaolletes, we went for my birthday last year.", "Sounds nice."],
	["2026-06-10", "Saw a Hospital La Fe ad on the bus, felt weirdly nostalgic already.", "Endings are strange."],
	["2026-07-18", "Sam says his old car in Valencia had a cassette player.", "Classic."],
	["2026-08-02", "My colleague Pablo runs marathons, his best is 3:12.", "Impressive."],
	["2026-08-24", "Lucía sent the new invitations, the design is lovely.", "Exciting."],
	["2026-09-05", "A neighbour's dog, a husky, keeps howling at night.", "Hope it settles down."],
	["2026-09-12", "Read an article about cycling in Lisbon: lots of hills.", "An e-bike will help there."],
];

/** Everyday chatter. */
const CHATTER = [
	["Can you suggest something quick for dinner tonight?", "How about a vegetable stir-fry with rice?"],
	["Remind me to call the bank tomorrow morning.", "I'll remind you tomorrow at 9."],
	["What's a good stretch for tight calves?", "Try a wall calf stretch, 30 seconds each side."],
	["I'm so tired today, long shift.", "Rest well. Want me to keep tomorrow light?"],
	["Any podcast recommendations for the commute?", "Try a short daily news show or an audio drama."],
	["Help me write a message to my landlord about the boiler.", "Here's a short, polite draft."],
	["What's the weather like this weekend?", "Mostly sunny, a little wind on Sunday."],
	["Add oat milk and lentils to the shopping list.", "Added both."],
	["How long should I boil eggs for soft yolks?", "About six and a half minutes."],
	["I need a gift idea for a colleague leaving the team.", "A nice plant or a book they mentioned."],
	["Can you summarize this article for me later?", "Send it over and I'll keep it short."],
	["My back hurts after the shift.", "Gentle stretching and heat might help."],
	["Plan a 30-minute easy run for tomorrow.", "Ten minutes easy, fifteen steady, five cool down."],
	["What should I pack for a day at the beach?", "Water, sunscreen, a hat and snacks."],
	["Tell me something interesting about octopuses.", "They have three hearts."],
	["I want to sleep better, any tips?", "Same bedtime, a dark room, and no screens late."],
	["How do I descale the kettle?", "Boil water with a splash of vinegar, then rinse."],
	["Suggest a film for tonight, something light.", "A feel-good comedy might be just right."],
	["Remind me to water the plants on Friday.", "Friday plant reminder set."],
	["Can you help me budget for next month?", "Sure, start with rent, food and transport."],
	["What's a good breakfast before a long run?", "Toast with banana and a little honey."],
	["I keep forgetting my keys.", "A hook by the door helps."],
	["Translate 'see you tomorrow' into French.", "À demain."],
	["Write a short thank-you note for my team.", "Thanks for all the support this week, it made a difference."],
	["How many minutes of exercise a day is enough?", "About 30 minutes most days is a good target."],
	["I need a recipe that uses chickpeas.", "Chickpea curry with spinach is quick."],
	["What time does the pharmacy close on Sundays?", "Usually early afternoon; check the local listing."],
	["Ugh, the washing machine is leaking.", "Check the door seal and the hose first."],
	["Give me a two-minute breathing exercise.", "Breathe in for four, hold four, out for six, repeat."],
	["Remind me about the dentist on Thursday at 5.", "Dentist reminder set for Thursday 17:00."],
	["What's a nice houseplant that survives neglect?", "A snake plant or a pothos."],
	["How do I get coffee stains off a mug?", "Baking soda paste and a gentle scrub."],
	["I finished a chapter, it was slow.", "Some chapters are like that; it may pick up."],
	["Can you set a timer for 20 minutes?", "Timer set for 20 minutes."],
	["Sam is cooking tonight, finally a break.", "Enjoy the night off."],
	["What's the difference between a latte and a flat white?", "A flat white has less milk and a thinner foam."],
	["I need a playlist for cleaning the flat.", "Upbeat pop from the 2000s works well."],
	["Help me reply to a group chat about Saturday plans.", "Something like: count me in, what time?"],
	["Is it okay to run two days in a row?", "Yes, if one of them is easy."],
	["Suggest a short stretch routine after work.", "Neck rolls, hamstring stretch, child's pose."],
];

const messages = [];
const seen = new Set();
function add(dayIndex, minutes, who, text) {
	const at = new Date(START + dayIndex * 86_400_000 + minutes * 60_000).toISOString();
	messages.push({ at, from: who, text });
}

const fixed = new Map();
for (const [iso, said, answer] of [...FACTS, ...DECOYS]) {
	const d = day(iso);
	fixed.set(d, [...(fixed.get(d) ?? []), [said, answer]]);
}

for (let d = 0; d < DAYS; d++) {
	// About five exchanges a day, the day's facts somewhere among them.
	const exchanges = 5 + Math.floor(rand() * 2);
	const todays = fixed.get(d) ?? [];
	const slots = Array.from({ length: exchanges }, () => null);
	todays.forEach((f, i) => (slots[Math.min(slots.length - 1, Math.floor(rand() * slots.length) + i) % slots.length] = f));
	let minutes = 30 + Math.floor(rand() * 60);
	for (const slot of slots) {
		let pair = slot;
		if (!pair) {
			do pair = pick(CHATTER);
			while (seen.has(`${d}:${pair[0]}`));
			seen.add(`${d}:${pair[0]}`);
		}
		add(d, minutes, "Alex", pair[0]);
		add(d, minutes + 1, "Kit", pair[1]);
		minutes += 40 + Math.floor(rand() * 120);
	}
	// A fact that didn't fit (two on one day) still goes in.
	for (const f of todays) if (!slots.includes(f)) {
		add(d, minutes, "Alex", f[0]);
		add(d, minutes + 1, "Kit", f[1]);
		minutes += 30;
	}
}

/**
 * Questions, asked on 30 September. `expect`: regular expressions, all must match the answer; `forbid`: none may.
 * Paraphrased: few share their key words with the message that holds the answer.
 */
const QUESTIONS = [
	// Current state, after changes
	{ type: "current", q: "Which city does Alex call home at the moment?", expect: ["madrid"], forbid: ["^(?!.*madrid).*valencia"] },
	{ type: "current", q: "Where is Alex headed after this place?", expect: ["lisbon|lisboa"] },
	{ type: "current", q: "Which hospital employs Alex now?", expect: ["mara[ñn][oó]n"] },
	{ type: "current", q: "What is Alex's job title these days?", expect: ["charge nurse"] },
	{ type: "current", q: "Does Alex still work nights?", expect: ["\\bno\\b|day shift|days"], forbid: ["\\byes\\b"] },
	{ type: "current", q: "How many dogs live with Alex now?", expect: ["\\btwo\\b|\\b2\\b"] },
	{ type: "current", q: "How would you describe Alex's diet now?", expect: ["pescatarian|fish"] },
	{ type: "current", q: "When will Lucía get married?", expect: ["nov"], forbid: ["^(?!.*nov).*oct"] },
	{ type: "current", q: "How does Alex usually get to the hospital?", expect: ["bike|cycl"] },
	{ type: "current", q: "Does Alex own a car right now?", expect: ["\\bno\\b|sold|doesn.?t|does not"] },
	{ type: "current", q: "Which book is Alex reading at the end of the summer?", expect: ["overstory"] },
	{ type: "current", q: "Which language is Alex learning, and with whom?", expect: ["portuguese", "in[eê]s"] },
	// The past
	{ type: "past", q: "Where did Alex live before the move in June?", expect: ["valencia"] },
	{ type: "past", q: "What ward did Alex switch to when changing hospitals?", expect: ["pediatric|paediatric|children"] },
	{ type: "past", q: "What was the wedding date originally?", expect: ["oct"] },
	{ type: "past", q: "Which shifts was Alex working in April?", expect: ["night"] },
	{ type: "past", q: "What was Alex's diet before the doctor's advice?", expect: ["vegetarian"] },
	{ type: "past", q: "Why couldn't Alex have a dog in the first flat?", expect: ["landlord|allow"] },
	// Events
	{ type: "event", q: "What did Alex cook for the housewarming?", expect: ["paella"] },
	{ type: "event", q: "What was Alex's finishing time in the 10K?", expect: ["52:30"] },
	{ type: "event", q: "How long did the half marathon take Alex?", expect: ["1:58"] },
	{ type: "event", q: "How much money did Alex get for the old car?", expect: ["2[,.]?800"] },
	{ type: "event", q: "What present did Alex want for Sam's birthday?", expect: ["camera"] },
	{ type: "event", q: "Which region did Alex visit on holiday in August?", expect: ["asturias|cangas"] },
	{ type: "event", q: "What operation did Alex's mother have?", expect: ["knee"] },
	{ type: "event", q: "Why did the wedding move?", expect: ["flood"] },
	{ type: "event", q: "What's the name of the second dog, and what kind of dog is it?", expect: ["pico", "greyhound"] },
	{ type: "event", q: "When is Sam's birthday?", expect: ["aug(ust)?\\s*14|14\\s*(of\\s*)?aug"] },
	{ type: "event", q: "Which neighbourhood did they move into in Madrid?", expect: ["chamber[ií]"] },
	{ type: "event", q: "Where will they rent in Lisbon?", expect: ["alfama"] },
	// Stable facts, paraphrased
	{ type: "stable", q: "Is there a nut Alex has to avoid?", expect: ["cashew"] },
	{ type: "stable", q: "What does Alex's partner do for a living?", expect: ["sound|audio"] },
	{ type: "stable", q: "How does Alex like replies to be?", expect: ["short|brief|concise"] },
	{ type: "stable", q: "What's the name of the beagle?", expect: ["toffee"] },
	{ type: "stable", q: "Where does Alex like to get coffee in the new city?", expect: ["hola"] },
	{ type: "stable", q: "What brand is Alex's e-bike?", expect: ["orbea"] },
	// Never said: the right answer is not knowing
	{ type: "unknown", q: "What is the name of Alex's brother?", expect: ["know|not sure|no (information|record|mention)|haven.?t|didn.?t|don.?t have|not mentioned"] },
	{ type: "unknown", q: "Which gym is Alex a member of?", expect: ["know|not sure|no (information|record|mention)|haven.?t|didn.?t|don.?t have|not mentioned"] },
	{ type: "unknown", q: "What is Alex's blood type?", expect: ["know|not sure|no (information|record|mention)|haven.?t|didn.?t|don.?t have|not mentioned"] },
	{ type: "unknown", q: "What instrument does Sam play?", expect: ["know|not sure|no (information|record|mention)|haven.?t|didn.?t|don.?t have|not mentioned"] },
];

const out = { name: "memory-2000", about: "Six months of Alex and their assistant Kit, 2026-04-01 to 2026-09-30. See build-set.mjs.", today: "2026-09-30", people: { user: "Alex", agent: "Kit" }, messages, questions: QUESTIONS };
const file = join(dirname(fileURLToPath(import.meta.url)), "memory-2000.json");
writeFileSync(file, `${JSON.stringify(out, null, "\t")}\n`);
console.log(`${messages.length} messages, ${QUESTIONS.length} questions → ${file}`);
