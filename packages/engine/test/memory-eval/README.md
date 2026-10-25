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
| **Standard + learned facts** (small, M2, first prompt) | 35/36 | **38/40** | 11/12 | 6/6 | 11/12 | 6/6 | 4/4 | 603 ms |
| **Standard + learned facts** (small, M2, tuned) | 35/36 | **39/40** | 11/12 | 6/6 | 12/12 | 6/6 | 4/4 | 595 ms |
| Apple on-device, sentence embedding | 14/36 | — | 4/12 | 1/6 | 6/12 | 3/6 | — | 60 ms |
| Apple on-device, contextual embedding (mean-pooled) | 20/36 | — | 7/12 | 2/6 | 8/12 | 3/6 | — | 205 ms |

- **Hybrid recall is the gain.** It took 25/40 to 38/40. A keyword match misses paraphrases: "Which city does Alex call home" shares no word with "First night in the new flat in Chamberí".
- **Apple's on-device embeddings** (NaturalLanguage, no download) did worse than keyword search alone, so Piopio doesn't offer them. Run them with `PIOPIO_NL_EMBED=<helper>`; the helper is a 30-line Swift program over `NLEmbedding.sentenceEmbedding` and `NLContextualEmbedding`.
- **Small vs large:** the large model adds one right answer at six times the price. Small stays the default.
- **Where the time goes:** nearly all of the ~650 ms is the round trip to OpenRouter to embed the question. The vector scan of 2,018 records takes about 1 ms.
- **Cost:** embedding the whole set is $0.0036 (47k tokens). The 120 answers cost $0.021.
- **What hybrid still misses:**
  - "What is Alex's job title these days?" (the promotion is one message among 2,000);
  - "What was Alex's diet before the doctor's advice?" (the vegetarian message is from April).

  Both are changes over time, which is what learned facts (M2) are for.

## Learned facts (M2)
- **How it ran:** one learning step per day of conversation, the way agents batch a quiet conversation's exchanges. The utility model (`anthropic/claude-haiku-5.5`) extracted facts and decided add, replace, end or nothing against the closest known facts. Raw messages stay searchable next to the facts.
- **What it learned:** 85 current facts and 38 replacements over six months, for **$0.06** of utility model in total (183 steps).
- **The gain:** past questions went to 6/6 ("Where did Alex live before the move?"). The first prompt then lost an event; the tuned one (a clearer "a newer fact about the same thing replaces the older one", and current facts weighing 1.3× in recall) got everything else right.
- **Still open:**
  - **Some stale facts stay current:** the old hospital, "vegetarian for six years", night shifts. Each day's step sees only the closest facts, and the model sometimes keeps both. A periodic tidy-up of an agent's facts is the follow-up.
  - **The promotion isn't recalled:** "What is Alex's job title these days?" still misses. The promotion fact exists, but 2,000 raw messages crowd it out of the 1,200-token budget.

Reports: [results/](results/) (`-learned-v1` is the first prompt).
