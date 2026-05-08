# Changelog

All notable changes to pyx are recorded here. Format roughly follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); each release
is grouped under its version. Pre-release work since the most recent
tag goes under `## Unreleased`.

## Unreleased

### Added
- Compound indexes (Zig core, phase 1 of 3): `Db.createCompoundIndex`,
  `Db.dropCompoundIndex`, `Collection.findOneCompound`. The index is
  ordered — `(last, first)` is a different index from `(first, last)`
  and only the former answers a `last + first` lookup. Auto-maintained
  on insert / put / delete; persisted in two new namespaces (\x03 for
  the registry, \x04 for entries) so existing single-field indexes are
  unaffected. v1 limits: equality-only, no range on the trailing
  field, max 16 fields per index.
- Compound indexes (phase 2 — bindings):
  - C ABI: `pyx_create_compound_index`, `pyx_drop_compound_index`,
    `pyx_compound_find_one`. Field lists are passed as a `(char**,
    size_t*, n_fields)` triple, mirroring Zig's `[]const []const u8`.
  - Python: `Db.create_index(coll, *fields)` is now variadic — pass 1
    field for single, 2+ for compound. `Db.drop_index` matches.
    `Collection.find_one(**kwargs)` resolves to the compound index
    whose ordered fields match the kwarg keys; `find_one("field",
    value)` still works for single-field. Mixing positional and
    kwargs is a TypeError.
  - 1 new C-ABI test, 5 new Python tests.
- `Pager.flushForSnapshot` — soft-flush variant that pwrites the dirty
  page cache into the kernel page cache without fsync or WAL truncate.
  `Db.snapshot()` uses it instead of `checkpoint`, dropping snapshot
  capture latency from ~75 µs to ~15 µs in the OCC steady state.
- `pyx-bench-snapshot` build target for snapshot-capture latency
  regression testing.
- OCC implicit-read on `put` / `delete` — closes the lost-update gap
  for blind writes; concurrent committers who modify a written key
  trigger `error.WriteConflict` at commit.
- OCC range-read tracking for `findOne`, `findAll`, `findRange`, and
  full-collection `iterator`. Match lists are captured at read time
  and re-validated against the live tree at commit. New
  `TxnMatchIterator` and `TxnIterator` types replace the regular
  iterator types inside an OCC txn.
- `Db.runOptimistic` exponential backoff with full jitter (cap doubles
  from 100 µs up to 10 ms; sleep uniformly drawn from `[0, cap)`).
- README "Snapshot capture latency" subsection with numbers from
  `pyx-bench-snapshot`.
- C ABI surface for OCC: `pyx_optimistic_txn` opaque handle plus
  `pyx_begin_optimistic`, `pyx_optimistic_commit/abort`,
  `pyx_optimistic_insert/put/get/delete`, and
  `pyx_optimistic_find_one`. New status codes `PYX_WRITE_CONFLICT`
  (-12) and `PYX_RETRY_BUDGET_EXHAUSTED` (-13).
- Python OCC wrapper: `Db.begin_optimistic()`, `Db.run_optimistic(fn,
  max_attempts)` with exponential backoff + full jitter, and the
  `OptimisticTxn` / `TxnCollection` classes mirroring the Zig API.
  `WriteConflict` and `RetryBudgetExhausted` exceptions.
- Python `find_range` now accepts bare scalars as inclusive
  shorthand (`users.find_range("age", 18, 65)`) and SQL-style kwargs
  (`gte=`, `gt=`, `lte=`, `lt=`) in addition to the explicit
  `Bound.inclusive` / `Bound.exclusive` API.
- `CHANGELOG.md` (this file) — kept up-to-date on every push from
  here on.

### Changed
- README benchmark tables refreshed against latest runs (twice in
  this cycle); shape unchanged within run-to-run variance.
- README Zig and C quick-starts now include OCC examples (the
  Python one already had `run_optimistic`).
- README Python quick-start showcases the new `find_range`
  ergonomics and includes an OCC `run_optimistic` example.
- README concurrency-model section now describes phantom protection
  semantics in detail and the `TxnMatchIterator`/`TxnIterator` API
  shape.
- bindings/python/README updated: optimistic-transactions section,
  three styles of `find_range`, accurate concurrency note (OCC reads
  are lock-free).
- README project layout adds `CHANGELOG.md`.

## 0.2.0 — 2026-05-08

First tagged release.

### Added
- Group commit: leader/follower fsync coalescing in the WAL
  (`Wal.syncToLsn`). N concurrent writers in `.full` mode share a
  single fsync syscall when their `commitAppend`s overlap the leader's
  syscall.
- Optimistic concurrency: `Db.beginOptimistic`, `OptimisticTxn`,
  `TxnCollection`, `Db.runOptimistic` retry helper, and
  `error.WriteConflict` / `error.RetryBudgetExhausted`. Lock-free
  snapshot reads, buffered writes, validate-and-apply at commit.
- Lock-free atomic doc-id reservation (`Pager.reserveDocId`) for
  concurrent OCC writers.
- Apache-2.0 LICENSE.
- Logo and detailed README with architecture diagram, multi-language
  quick-start, and benchmark tables.
- Concurrent benchmark phases C (multi-writer auto-commit `.full`) and
  D (multi-writer OCC RMW); `bench_concurrent` now reports
  group-commit diagnostic counters (`leader_cycles`, `follower_waits`,
  `fast_returns`, `fsync_total_ns`).

### Changed
- `Pager.commit` split into `commitAppend` / `syncTo` /
  `applyAndFinalize`. `db.zig` writes release `db.mu` between
  apply and fsync, enabling group-commit coalescing.

[Unreleased]: https://github.com/parisxmas/pyx/compare/v0.2.0...HEAD
[0.2.0]: https://github.com/parisxmas/pyx/releases/tag/v0.2.0
