# Memory test set M0 (docs/spec/14-memory §5.5)

Six months of Alex talking with their assistant Kit, 1 April to 30 September 2026: **2,018 messages** with
facts that change several times, decoys that share words with the questions, and **40 questions** asked on
30 September. Built by [build-set.mjs](build-set.mjs) (deterministic), run by
[scripts/memory-eval.mjs](../../../../scripts/memory-eval.mjs).

**The facts:**
- **City:** Valencia → Madrid (Chamberí) in June → Lisbon (Alfama) planned for October.
- **Job:** a nurse at La Fe on nights → pediatrics at Gregorio Marañón on days → charge nurse.
- **Pets:** none (the landlord won't allow them) → Toffee, a beagle mix → plus Pico, a greyhound.
- **Diet:** vegetarian → pescatarian.
- **Family:** the sister's wedding moved from 3 October to 7 November.
- **The rest:** a car sold, races and their times, books, a holiday, allergies, a tutor.

**The questions:**

| Type | Count | Example |
|---|---|---|
| Current state | 12 | "Which city does Alex call home at the moment?" |
| Past state | 6 | "Where did Alex live before the move in June?" |
| Events | 12 | "How long did the half marathon take Alex?" |
| Stable facts | 6 | "Is there a nut Alex has to avoid?" |
| Never said | 4 | "What is Alex's blood type?" (right answer: not knowing) |

**How each question is scored:**
- **Recall holds the answer:** the agents' 1,200-token recall, formatted as the agents format it, contains the answer. This is free to measure, and it's the memory's own score.
- **Answered right:** the answering model, given that recall, answers right, checked by regular expressions.
- **Same for every engine:** the answering model is `anthropic/claude-haiku-5.5` through OpenRouter.

## Results (2026-10-25)

| Engine | Recall holds the answer | Answered right | Current | Past | Events | Stable | Never said | Recall time |
|---|---|---|---|---|---|---|---|---|
| **Basic** (keyword + recency, before M1) | 21/36 | **25/40** | 7/12 | 3/6 | 8/12 | 3/6 | 4/4 | 4 ms |
| **Standard, small** (+ `text-embedding-3-small` at 256) | 34/36 | **38/40** | 11/12 | 5/6 | 12/12 | 6/6 | 4/4 | 645 ms |
| **Standard, large** (+ `text-embedding-3-large` at 256) | 34/36 | **39/40** | 11/12 | 6/6 | 12/12 | 6/6 | 4/4 | 701 ms |

- **Hybrid recall is the gain.** It took 25/40 to 38/40. A keyword match misses paraphrases: "Which city does Alex call home" shares no word with "First night in the new flat in Chamberí".
- **Small vs large:** the large model adds one right answer at six times the price. Small stays the default.
- **Where the time goes:** nearly all of the ~650 ms is the round trip to OpenRouter to embed the question. The vector scan of 2,018 records takes about 1 ms.
- **Cost:** embedding the whole set is $0.0036 (47k tokens). The 120 answers cost $0.021.
- **What hybrid still misses:**
  - "What is Alex's job title these days?" (the promotion is one message among 2,000);
  - "What was Alex's diet before the doctor's advice?" (the vegetarian message is from April).

  Both are changes over time, which is what learned facts (M2) are for.

Reports: [results/](results/).
