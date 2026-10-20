# Spike S6: Hindsight as Piopio's memory provider

**Question** (09-roadmap): can the engine run [Hindsight](https://github.com/vectorize-io/hindsight) locally, on demand, at a cost a Mac app can carry, and is it worth it over the built-in provider (07-shared §5.1)?

**Answer:** it runs well locally, recall is fast, and memory use is moderate. But it is a 2 GB opt-in with several runtime downloads outside the signed app, and on this test set it was only one question better than the built-in baseline. **Recommendation:** keep the built-in provider as the default and offer Hindsight as an opt-in provider for Agents (Phase 4), local or remote. Before deciding on a default, run a harder test set.

Measured on 2026-10-21 on a MacBook Air (Apple M4, 16 GB RAM, 17 GB free disk), with Hindsight 1.0.0 (`hindsight-api`, the full package with local models), Python 3.12 through uv 0.13.4, and OpenRouter `anthropic/claude-haiku-5.5` for extraction and answers. Everything ran from a throwaway folder (`HOME` pointed into it), so nothing was installed on the Mac.

## Footprint

| | Measured |
|---|---|
| Install (`uv pip install hindsight-api`) | 22 s; **1.9 GB downloaded, 1.8 GB installed** (torch, transformers, sentence-transformers, onnxruntime, pg0) |
| First start | **52 s** to `/health`, including the first model download (BGE embedder and MiniLM reranker, 225 MB in `~/.cache/huggingface`) and Postgres 18.1 binaries (36 MB in `~/.pg0`, downloaded by `pg0` at runtime) |
| Warm start | **17 s** |
| RAM | API process 250–300 MB idle (805 MB peak while loading models), 670 MB with 20k items. Embedded Postgres: 16 processes, about 70 MB |
| Disk per bank | 200 messages with extraction: about 25 MB over an empty instance (116 facts and observations, 2,073 links). **20k raw items: 1.4 GB** (about 70 KB per item) |
| Hardware | Local models run on the CPU: Hindsight turns off Apple's GPU (MPS) because it leaks memory |
| Ports | API on any chosen port; `pg0` picks a free Postgres port (5432, then 5433…) |

## Cost and latency

| | Measured |
|---|---|
| Retain with extraction | 80 calls (one per day of conversation, 200 messages): **213 s, 2.6 s median per call; 914k tokens; $0.14** with claude-haiku-5.5, i.e. **about $0.07 per 100 messages**. Background consolidation (observations) finished 12 s later |
| Retain without extraction (`LLM provider none`) | about 340 items/s with local embeddings, 1k and 20k items alike (`scale.mjs`) |
| Recall | **250 ms median, 290 ms p90, flat from 1k to 20k items**; 324 ms median on the extracted bank |
| Reflect (Hindsight's own answer) | **7.4 s median** with `budget: "low"`. Too slow for every turn; fine on demand |
| Answering 30 questions × 3 ways, plus judging | $0.22 |

OpenRouter needs one setting: `HINDSIGHT_API_LLM_OPENAI_COMPATIBLE_JSON_MODE=false`. By default Hindsight asks OpenRouter for JSON mode with `require_parameters`, and no endpoint serving claude-haiku-5.5 accepts it ("No endpoints found that can handle the requested parameters"). With the setting, the schema goes in the prompt.

## Quality

The set (`conversation.json`, built by `make-conversation.mjs`) has 200 messages to a personal agent over three months. They come from the owner, Alex, and contacts Marta, Luis and Sam. 34 messages carry facts, many of which change later (city, address, car, gym, a deadline, a restaurant, the Christmas plan); the rest is everyday noise. 30 questions are asked "on June 1": 13 plain facts, 13 changed facts (the current value counts) and 4 "who said it". Each way answers from its own memory with the same model and prompt, and the same model judges against the expected answer (`quality.mjs`).

| | Right | Facts | Changed | Who |
|---|---|---|---|---|
| Built-in baseline (BM25 + recency over the raw messages, top 10) | **29/30** | 13/13 | 12/13 | 4/4 |
| Hindsight recall → same answerer | **30/30** | 13/13 | 13/13 | 4/4 |
| Hindsight reflect | **30/30** | 13/13 | 13/13 | 4/4 |

The baseline's miss: "Which city does Alex live in now?" got "Valencia". "I live in Valencia" matches the question's words; the later "we're moving to Madrid" and "New address … Madrid" don't. Hindsight had extracted "Alex lives in the Chamberí district of Madrid". This is the kind of miss that grows with a longer history and with questions phrased differently from the facts.

**Limits of this set:** 200 messages are few enough that the baseline's top 10 usually holds the answer. Most questions share words with their facts, which favours keyword search. So this set can't separate the two well. A harder set would: 2,000+ messages, paraphrased questions, more facts that change several times. Its retain would cost about $1.40 at the rate above.

## Transparency

Hindsight meets the rule that every memory write must be visible (07-shared §5.1):
- **List:** `GET …/memories/list` returns every fact and observation with its type, source document and chunk, dates, proof count and state.
- **Edit or invalidate:** `PATCH …/memories/{id}` edits a fact, or invalidates and reverts it. Invalid facts leave recall but are kept for audit. Observations are derived and can't be edited, but `…/history` shows how each one changed.
- **Push:** webhooks (`HINDSIGHT_API_WEBHOOK_URL`, event types) can report extraction and consolidation as they happen, so Piopio's memory views wouldn't need to poll.
- `memories/dry-run-extract` previews what a message would store, without storing it.

## Packaging

What a local Hindsight would make Piopio run **from outside its signed, notarized bundle**:
- **uv**, which stock macOS doesn't have. Piopio would bundle a signed `uv` binary (about 35 MB), or install it when the user opts in.
- **A Python 3.12 runtime and about 1.9 GB of PyPI wheels** (torch among them), downloaded by uv.
- **Model weights from Hugging Face** (225 MB) on first start.
- **Postgres 18.1 binaries** downloaded by `pg0` on first start.

None of this is quarantined or covered by notarization. It is code from the internet that Piopio starts, so it needs an explicit opt-in that says what is downloaded and how big it is. Plan for 2.2 GB on disk before any data. With 17 GB free on this Mac, it's a real cost.

`@vectorize-io/hindsight-all` (npm) already does the supervising: it runs `hindsight-embed` through `uvx`, waits for `/health`, and stops it. The engine could use it, or do the same in about 100 lines. The 17 s warm start means the daemon should keep running alongside the engine (with background mode), not start per request.

**Smaller option, not measured:** `hindsight-api-slim` has no local models (about 1.8 GB less). It needs remote embeddings, which OpenRouter can serve (`HINDSIGHT_API_EMBEDDINGS_PROVIDER=openrouter`), and a remote reranker, whose providers the docs list without OpenRouter. If the reranker can be dropped or served through OpenRouter, the opt-in shrinks to roughly the size of Python plus Postgres.

## Recommendation

1. **Built-in provider stays the default** (AQ11). It costs nothing, is in-process, and did 29/30 here.
2. **Hindsight is an opt-in provider for Agents** in Phase 4, first through a **remote URL** (self-hosted or Hindsight Cloud: no local footprint). Then a **local daemon**, with a download prompt that gives the size, `HINDSIGHT_API_LLM_OPENAI_COMPATIBLE_JSON_MODE=false`, and the utility model for extraction.
3. Use **recall**, not reflect, in each turn's system section (300 ms versus 7 s). Offer reflect as a tool for questions that need reasoning over the whole history.
4. **Before reconsidering the default,** run the harder set above and measure `hindsight-api-slim` with OpenRouter embeddings.

## Files

- `make-conversation.mjs`, `conversation.json`: the quality set.
- `quality.mjs`: the baseline and Hindsight on the set, answered and judged; it reports OpenRouter cost from the key's usage.
- `scale.mjs`: ingestion and recall at 1k and 20k items on an instance without extraction.
- `start.sh.example`: how the instances were started.
- `results/`: the reports of this run.
