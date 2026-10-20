// Builds conversation.json for spike S6: 200 messages to a personal agent over three months (the owner, Alex, and
// two contacts, Marta and Luis), mixing facts that later change with everyday noise, plus 30 questions with the
// answer that counts as right. Deterministic: same output every run.
import { writeFileSync } from "node:fs";

let seed = 7;
const rand = () => ((seed = (seed * 1103515245 + 12345) % 2 ** 31) / 2 ** 31);
const pick = (a) => a[Math.floor(rand() * a.length)];

// [day (0 = 2026-03-01), speaker, text, reply]. Facts; the rest is filler.
const facts = [
	[1, "Alex", "Quick intro so you know me: I live in Valencia, near the Turia park.", "Got it: you live in Valencia, near the Turia park."],
	[2, "Alex", "My dog is called Kiwi. Her vet is Dr. Ruiz on Calle Colón.", "Noted: Kiwi, vet Dr. Ruiz on Calle Colón."],
	[3, "Alex", "I'm lactose intolerant, keep that in mind for restaurant ideas.", "Noted, no dairy-heavy suggestions."],
	[4, "Alex", "Book my dentist for March 3 at 9am please.", "Dentist booked: March 3, 9am."],
	[5, "Marta", "Hi, I'm Marta, Alex's sister. My birthday is April 12, in case Alex forgets!", "Thanks Marta, April 12 noted."],
	[6, "Marta", "Also: I'm allergic to nuts, so no nut cakes for me.", "Noted: no nuts for Marta."],
	[8, "Alex", "Gym days are Mondays and Thursdays, don't schedule calls then after 6pm.", "Mondays and Thursdays after 6pm are blocked."],
	[9, "Luis", "Luis here, Alex's coworker. I prefer meetings after 10am, never earlier.", "Got it Luis: meetings after 10am."],
	[10, "Luis", "Our project Atlas has its deadline on June 1.", "Atlas deadline: June 1."],
	[11, "Alex", "Favourite restaurant: La Pepica on the beach. Good for special dinners.", "La Pepica noted as your favourite."],
	[12, "Alex", "I drive a blue Seat Ibiza, plate 4821 KLM, for parking bookings.", "Car noted: blue Seat Ibiza."],
	[14, "Alex", "Savings goal: put away 500€ every month.", "Goal set: 500€/month."],
	[15, "Alex", "Book club is reading Dune this month.", "Dune for March, noted."],
	[16, "Alex", "Move the dentist to March 10, same time.", "Dentist moved to March 10, 9am."],
	[18, "Sam", "Hi, I'm Sam, Alex's partner. I'm a nurse; in April I'm on night shifts.", "Thanks Sam, night shifts in April noted."],
	[20, "Luis", "The client meeting for Atlas will be in Lisbon, not Madrid.", "Atlas client meeting: Lisbon."],
	[23, "Alex", "Kiwi's vaccines are due on April 2.", "Kiwi's vaccines: April 2."],
	[26, "Marta", "I'll host Christmas dinner this year at my place in Alicante.", "Marta hosts Christmas in Alicante."],
	[30, "Alex", "Big news: we're moving to Madrid in April, to Chamberí.", "Congrats! Moving to Madrid, Chamberí, in April."],
	[33, "Alex", "Book club switched: April book is Klara and the Sun.", "April book: Klara and the Sun."],
	[36, "Alex", "Sold the Seat Ibiza today.", "Noted, the Seat is sold."],
	[38, "Alex", "Bought a used Tesla Model 3, white.", "Car updated: white Tesla Model 3."],
	[41, "Luis", "Atlas deadline moved to June 15, client asked for more time.", "Atlas deadline now June 15."],
	[44, "Alex", "Gym changed: now only Tuesdays.", "Gym is now Tuesdays only."],
	[47, "Alex", "We've moved. New address is Calle Fernández de los Ríos 12, Madrid.", "Address updated to Fernández de los Ríos 12, Madrid."],
	[50, "Alex", "Honestly La Pepica got worse; my favourite now is Casa Montaña.", "Favourite restaurant now Casa Montaña."],
	[53, "Alex", "Raise the savings goal to 700€ a month.", "Savings goal now 700€/month."],
	[56, "Luis", "I'm on holiday from May 5 to May 16, ask Ana for Atlas meanwhile.", "Luis away May 5–16; Ana covers Atlas."],
	[60, "Alex", "Flight to Lisbon booked: TAP on May 20 at 7:40.", "Lisbon flight: TAP, May 20, 7:40."],
	[63, "Sam", "My night shifts are over, back to days from May 1.", "Sam back on day shifts from May 1."],
	[67, "Alex", "Kiwi has a new vet in Madrid: Clínica Veterinaria Chamberí.", "Kiwi's vet is now Clínica Veterinaria Chamberí."],
	[72, "Marta", "Change of plans: Christmas will be at Mum's in Valencia, not my place.", "Christmas moved to your mum's in Valencia."],
	[78, "Alex", "Remind me: Marta likes lemon cake.", "Marta likes lemon cake, noted."],
	[85, "Alex", "My new gym is Basic-Fit Chamberí.", "Gym: Basic-Fit Chamberí."],
];

const filler = [
	"What's the weather like tomorrow?", "Can you find a recipe for dinner, something quick?", "Translate 'see you soon' to Portuguese.",
	"Any good podcast for the commute?", "Remind me to water the plants.", "How long does it take to boil an egg?",
	"What's 18% of 230?", "Suggest a movie for tonight.", "Is it worth getting a heat pump?", "How do I clean a coffee grinder?",
	"Summarize the news headlines.", "Find me a running route of 5k.", "What's a good gift for a coworker?",
	"How do I remove a red wine stain?", "Explain how compound interest works.", "Write a short thank-you note.",
	"What time is sunset today?", "Recommend a board game for four.", "How many steps did I do this week?", "What's a quick stretch for back pain?",
];
const fillerReplies = ["Here you go.", "Done.", "Sure, here are a few options.", "Here's a short answer.", "Noted."];

const days = new Map();
for (const f of facts) days.set(f[0], [...(days.get(f[0]) ?? []), f]);
const messages = [];
const date = (d, minute) => new Date(Date.UTC(2026, 2, 1 + d, 8 + Math.floor(minute / 60), minute % 60)).toISOString();
for (let d = 0; d < 92 && messages.length < 200; d++) {
	let minute = Math.floor(rand() * 120);
	for (const [, speaker, text, reply] of days.get(d) ?? []) {
		messages.push({ at: date(d, minute), speaker, text, reply });
		minute += 7;
	}
	const extra = rand() < 0.7 ? 1 + Math.floor(rand() * 2) : 0;
	for (let i = 0; i < extra && messages.length < 200; i++) {
		messages.push({ at: date(d, minute), speaker: "Alex", text: pick(filler), reply: pick(fillerReplies) });
		minute += 11;
	}
}
while (messages.length < 200) messages.push({ at: date(91, 600 + messages.length), speaker: "Alex", text: pick(filler), reply: pick(fillerReplies) });
if (messages.length > 200) messages.length = 200;

// [question, the answer that counts as right, kind]
const questions = [
	["Which city does Alex live in now?", "Madrid", "changed"],
	["What is Alex's current street address?", "Calle Fernández de los Ríos 12, Madrid", "changed"],
	["What is the name of Alex's dog?", "Kiwi", "fact"],
	["Who is the dog's vet now?", "Clínica Veterinaria Chamberí", "changed"],
	["When is Alex's dentist appointment?", "March 10 at 9am", "changed"],
	["Is Alex lactose intolerant or allergic to nuts?", "Lactose intolerant (Marta is the one allergic to nuts)", "who"],
	["Who is allergic to nuts?", "Marta", "who"],
	["When is Marta's birthday?", "April 12", "fact"],
	["Where will Christmas dinner be this year?", "At their mum's in Valencia", "changed"],
	["Who said Christmas would be at Mum's?", "Marta", "who"],
	["What time does Luis prefer meetings?", "After 10am", "fact"],
	["What is the Atlas deadline now?", "June 15", "changed"],
	["Where is the Atlas client meeting?", "Lisbon", "fact"],
	["Who covers Atlas while Luis is on holiday?", "Ana", "fact"],
	["When is Luis on holiday?", "May 5 to May 16", "fact"],
	["Which car does Alex drive now?", "A white Tesla Model 3", "changed"],
	["What happened to the Seat Ibiza?", "It was sold", "changed"],
	["Which days does Alex go to the gym now?", "Tuesdays", "changed"],
	["Which gym does Alex use now?", "Basic-Fit Chamberí", "fact"],
	["What is Alex's favourite restaurant now?", "Casa Montaña", "changed"],
	["How much does Alex want to save each month?", "700€", "changed"],
	["What is the book club reading in April?", "Klara and the Sun", "changed"],
	["What did the book club read in March?", "Dune", "fact"],
	["What does Sam do for work?", "Nurse", "fact"],
	["Is Sam on night shifts in May?", "No, back on day shifts from May 1", "changed"],
	["When are Kiwi's vaccines due?", "April 2", "fact"],
	["When is Alex's flight to Lisbon and with which airline?", "May 20 at 7:40, TAP", "fact"],
	["Which neighbourhood in Madrid did Alex move to?", "Chamberí", "fact"],
	["What kind of cake does Marta like?", "Lemon cake", "fact"],
	["Who told the agent that the Atlas meeting is in Lisbon?", "Luis", "who"],
];

const facts_in = messages.filter((m) => facts.some((f) => f[2] === m.text)).length;
writeFileSync(new URL("./conversation.json", import.meta.url), JSON.stringify({ about: "Spike S6 quality set: 200 messages to a personal agent (Alex, the owner; Marta, Luis and Sam, contacts) from 2026-03-01 to 2026-05-31, and 30 questions asked at the end. Generated by make-conversation.mjs.", today: "2026-06-01", messages, questions: questions.map(([q, a, kind]) => ({ q, a, kind })) }, null, "\t"));
console.log(`${messages.length} messages (${facts_in} with facts), ${questions.length} questions`);
