# Spike S8: semantic search in the built-in memory provider, without an extension

**Question** ([14-memory §4](../../spec/14-memory.md)): can the built-in provider add semantic search with the
SQLite we already have, on `node:sqlite` on the Mac and on a Durable Object's storage, with no vector extension?

**Answer: yes.** Vectors go in an ordinary table as int8 BLOBs. A bank's vectors are loaded once into one typed array
and scanned in JavaScript. That's fast enough for every bank we expect to have (a person's bank or About me stays
under 10k records; a busy agent's whole history may reach 50k over years). Beyond that, an approximate index or
Hindsight.

## How it's measured
[bench.mjs](bench.mjs), run with `node docs/spikes/s8/bench.mjs [records…]` (default 10,000 and 50,000):
- **Table:** `memory_vectors (record_id, bank, model, vector BLOB)`, as proposed in 14 §5.4, in a throwaway file.
- **Vectors:** 256 dimensions, random unit vectors quantized to int8 (scale 127 / largest component).
- **Load:** the bank is read once into one `Int8Array`.
- **Queries:** 50 per size. Each is a stored vector with noise added, so the right answer is known. The scan is a
  plain integer dot product over every row, keeping the best.

The vectors are synthetic, so this measures storage and scan cost, not retrieval quality. Quality (which embedding
model, hybrid with FTS) is M0's job.

## Results
| | 10k records | 50k records |
|---|---|---|
| **Mobile session** (2.1 GHz Xeon, 2026-10-24) | 2.7 MB · **9 ms** per query | 13 MB · **44 ms** |
| **This Mac** (Apple M4, Node 24.8, 2026-10-25) | 3.1 MB · **1.9 ms** median (p90 2.0) | 15.5 MB · **9.7 ms** median (p90 9.8) |
| Nearest first | every query | every query (50/50 here) |

More from the M4 run:
- **Write:** 107 ms for 10k rows in one transaction, 534 ms for 50k.
- **Load into memory:** 7 ms for 10k, 50 ms for 50k.
- **Size:** the file here is a little bigger than the first run's because each row also stores the bank and model
  as text.

The S8 numbers in 14-memory come from a Claude mobile session whose code isn't in the repo. bench.mjs rebuilds the
same measurement so it can be rerun. A Durable Object should land between the two rows (the scan is plain
JavaScript; the load goes through `ctx.storage.sql`). It hasn't been measured in workerd yet; M1 does that.
