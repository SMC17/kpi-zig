# kpi-zig

Try the [self-contained task](docs/SELF_SERVE.md): `zig build demo`.

[![License: AGPL-3.0-or-later](https://img.shields.io/badge/License-AGPL--3.0--or--later-blue.svg)](LICENSE)
[![Zig](https://img.shields.io/badge/Zig-0.16-orange.svg)](https://ziglang.org/)

Cohort retention, funnels, growth accounting, and RFM segmentation in Zig 0.16. Ports [Zach Wilson](https://www.linkedin.com/in/eczachly)'s analytical-patterns module (I1–I4) from his [DataExpert.io](https://www.dataexpert.io) intermediate bootcamp to a single binary.

## Status

**v0.0.1 — 6/6 tests pass on Zig 0.16.** N-day cohort retention curve, multi-step funnel with contiguous-from-zero count, four-bucket growth decomposition (new / resurrected / retained / churned), RFM quintile scoring with named segments.

## What ships

- `retentionCurve(activities, cohort_signup_day, max_offset_days)` — daily-grain retention against the signup-cohort base.
- `funnelStats(events, num_steps)` — timestamp-ordered contiguous-from-zero step counting. A user who hit step 2 without hitting steps 0+1 does not count for step 2.
- `growthDecomposition(last_period, this_period, prior)` — `(new, resurrected, retained, churned)` over a `(last → this)` transition with `delta()` helper.
- `rfmQuintiles(customers, today)` — quintile binning per R, F, M dimension with binary-search-over-sorted-values. `RfmScore.segment()` returns one of `champion / new / at_risk / lost / active`.

## Build

```sh
zig build test                  # 6 unit tests
```

## Honest non-claims

- Retention is single-cohort. Multi-cohort matrices (the grid of `(signup_day, offset)` pairs) land in v0.0.2.
- Funnel order is strict-contiguous-from-zero. Out-of-order funnels (steps allowed to interleave) need a different semantic; v0.0.2 ships `funnelStatsRelaxed`.
- Quintile boundaries are integer-cut at `pos * 5 / N`. Ties at boundaries go to the higher quintile.
- Growth-accounting input is three slices; v0.0.2 ships an iterator-friendly streaming variant for large user bases.
- No SIMD. The summary functions are linear scans; the hot path is the HashMap. v0.0.2 ports the bitmap segments to `@Vector(N, u64)`.

## Credit

Concept adapted from [Zach Wilson](https://www.linkedin.com/in/eczachly) (DataExpert.io). Frontier port by Sean Collins (`sean@sunlitmoon.online`).

## License

AGPL-3.0-or-later. See `LICENSE`.
