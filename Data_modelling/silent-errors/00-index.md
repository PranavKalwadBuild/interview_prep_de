<!-- Part of Data_modelling: Silent Errors — Navigation Index -->

# Silent Errors in Data Modelling and Pipeline Architecture — Index

A reference library for **design-level bugs that produce no system errors but silently corrupt metrics,
distort analytics, or permanently destroy historical accuracy**. These are not SQL syntax mistakes —
they are architectural and modelling decisions that pass code review, run green in CI, and only surface
weeks or months later when a business stakeholder notices a number is wrong.

Each file covers 8–15 distinct patterns. Every pattern is structured as:
- **What it looks like** — the innocent design or query
- **What actually happens** — the silent wrong behaviour
- **Why it's insidious** — no error thrown, survives code review
- **Example** — SQL or pseudocode
- **Detection query / invariant** — how to catch it after the fact
- **Real-world consequence** — what business decision gets made wrong

## File Index

| File | Topic | Approx Lines |
|------|-------|-------------|
| 01-dimensional-model-traps.md | Fan-out, chasm, role-playing dimension misuse, conformed drift, junk NULL, bridge double-counting | 310 |
| 02-scd-and-history-corruption.md | Late-arriving facts hitting wrong snapshots, effective_to overlaps, full-refresh surrogate key wipe, Type 1 retroactive overwrite, Type 6 stale current_*, hash collision | 320 |
| 03-fact-table-silent-errors.md | Semi-additive misuse, factless fact double-counting, NULL FK silent drops, timezone grain mismatch, wrong-grain measure storage, snapshot stale carry-forward, pre-aggregated drill-down | 295 |
| 04-incremental-and-cdc-silent-bugs.md | Mutable watermark misses soft-deletes, late CDC skipped permanently, dual-write race, batch CDC captures only final state, out-of-order delete/insert, idempotency key collision across sources, dbt first-run vs incremental divergence | 320 |
| 05-modern-stack-medallion-dbt.md | Bronze schema drift breaking Silver, NULL vs empty string inconsistency, dbt view fan-out, OBT dimension staleness, on_schema_change append NULLs, dbt seed partial rebuild, Gold column rename silent NULLs | 310 |
| 06-grain-and-aggregation-integrity.md | Mixed-grain fact table, pre-aggregated drill-down, periodic snapshot SUM, mixed-period join, NULL propagation in multi-level aggregation, KPI recalculation silent history change, date spine zero vs missing | 295 |

## Why This Matters

Data bugs that throw exceptions get fixed quickly. **Data bugs that produce plausible-but-wrong answers persist for months.** The patterns in this library have caused:

- Incorrect revenue attribution that persisted through a fiscal year close
- Inventory reports inflated by 30x because balance was summed across time periods
- Customer segment analysis that silently compared different segmentation rules across a rebrand
- A KPI dashboard that retroactively changed historical numbers every time cost data was refined
- A pipeline that appeared green while producing wrong counts because soft-deletes were never propagated

## Reading Order

**Debugging a dimensional model:** 01 → 06 → 02

**Debugging a dbt / medallion stack:** 05 → 04 → 06

**Debugging SCD / history issues:** 02 → 03 → 04

**Full reference sweep:** 01 → 02 → 03 → 04 → 05 → 06

## Companion Files in This Repository

These silent-error patterns assume familiarity with the base modelling concepts. Cross-reference:

- `../06-grain-and-star-schema.md` — grain definition and star schema fundamentals
- `../07-galaxy-and-fact-types.md` — fact table types (transaction, snapshot, factless)
- `../08-dimension-types.md` — conformed, junk, role-playing, bridge, degenerate dimensions
- `../09-scd-types.md` — SCD Types 0–6 mechanics
- `../10-modern-stack.md` — Medallion, OBT, Data Vault 2.0
- `../12-edge-cases-and-performance.md` — late arriving facts, NULL handling
