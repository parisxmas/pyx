# Changelog

All notable changes to pyx are recorded here. Format roughly follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); each release
is grouped under its version. Pre-release work since the most recent
tag goes under `## Unreleased`.

## Unreleased

### Added
- Keyspace sharding, phase 1: `pager.bTreeRoot` / `pager.setBTreeRoot`
  are now parameterized by `CollectionId` (typedef `u32`, with
  `default_collection_id = 0` reserved for today's single-tree state).
  `BTree` carries its own collection id, threaded through from
  `Collection` / `SnapshotCollection` / `TxnCollection`. Pure refactor:
  every id resolves to the default, so behaviour is bit-identical and
  all 89 tests pass. The plumbing exists so phase 2's per-collection
  catalog (separate roots, separate WRITER lock byte ranges) can land
  without touching every call site again.

## 0.3.0 — 2026-05-08

The headline of 0.3.0 is **multi-process safety**: opening the same
`.pyx` file from N processes (e.g. `gunicorn --workers 4`) now Just
Works. Cross-process visibility of committed writes, a single
machine-wide WRITER lock around the commit pipeline, and a shared
`-shm` sidecar file mmap'd MAP_SHARED carry the runtime counters
that used to be per-process.

Verified empirically: 1000 parallel POSTs across 4 gunicorn workers
in ~1.2 s (≈830 commits/s aggregate, all 1000 docs preserved); 50
concurrent OCC edits of the same note all succeeding via auto-retry;
8 processes × 200 inserts → 1600 docs preserved per trial.

Other meaningful work in this release: **compound indexes** (Zig +
C ABI + Python; ordered prefix matching, max 16 fields), an OCC
hardening pass (implicit-read on `put`/`delete` to close the
lost-update gap; range-read tracking for `findOne`/`findAll`/
`findRange`/iterator with phantom protection at commit), exponential
backoff with full jitter in `runOptimistic`, and a soft-flush
snapshot path that drops capture latency from ~75 µs to ~15 µs.

### Changed
- README's "Concurrency model" lock-byte table updated to reflect
  the WRITER-only protocol (the RECOVERY byte is gone). Django
  example's verified-numbers paragraph adjusted to `~1.2 s,
  ≈830 commits/s` to match the latest re-run (within run-to-run
  variance of the 1.16 s number from the previous commit).

### Added
- Multi-process foundation, phase 1A: `src/shm.zig` introduces a
  `mydb.pyx-shm` sibling file, mmap'd MAP_SHARED by every opener.
  Layout reserves 4 KB for cross-process state (magic, version,
  shared atomic counters); `next_doc_id` is the first counter moved
  into shm.
- `realworldexamples/django/` — a working Django app using pyx as
  its primary store (no SQL, no ORM). Notes app demonstrates the
  practical patterns: `db.snapshot()` for lock-free list reads,
  `db.run_optimistic` for safe concurrent edits, compound index on
  `(user_id, tag)`, and the single-process deployment constraint.
  Includes README, settings, views, templates, and an editable
  `requirements.txt` that wires up the local Python binding.
  Verified end-to-end against `runserver`: empty list → create →
  list → detail → edit (OCC commit lands) → tag filter → delete →
  404. The template-language constraint that variable names can't
  start with `_` led to renaming the dict's `_id` key to `doc_id`
  in views and templates.
- Multi-process foundation, phase 2A+2B: cross-process write
  visibility actually works for the simple case.
  - shm gains `btree_root` atomic (phase 2A). `Pager.bTreeRoot`
    returns the in-process header during a txn (work-in-progress
    root) and the shm value otherwise (cross-process latest).
  - `applyAndFinalize` no longer accumulates committed pages in an
    in-process `page_cache`. Instead it pwrites every dirty page
    directly to the data file under the WRITER lock (kernel page
    cache visibility — no fsync; durability still on the WAL),
    then atomically stores `header.btree_root` into shm. Order of
    operations matters: pages first, then root, with `.release` /
    `.acquire` semantics.
  - `Pager.begin`, after acquiring WRITER, refreshes the in-process
    header's `btree_root`, `num_pages`, and `next_doc_id` from shm
    so a process that's been waiting on the lock builds on top of
    whatever was committed while it slept.
  - `Pager.checkpoint` now also takes the WRITER lock so it can't
    truncate the WAL during a concurrent committer's append.
  - Verified: two processes each inserting 200 docs into the same
    DB → 400 docs preserved, byte-identical to single-process.
- Multi-process under gunicorn `--workers 4` actually verified —
  the open path now uses the WRITER lock (byte 0) instead of the
  RECOVERY-shared-for-lifetime pattern. The previous protocol
  deadlocked: long-running workers held RECOVERY shared for life,
  blocking new openers' RECOVERY exclusive forever. The simpler
  "WRITER blocking around the entire open, released at success"
  pattern serialises opens with commits but doesn't keep any
  lock for the connection's lifetime — so an opener can always
  make progress as soon as the current writer releases.
  Verified: 1000 parallel POSTs across 4 gunicorn workers in
  1.16 s (~862 commits/s aggregate, all 1000 docs preserved),
  plus 50 concurrent OCC edits of the same note all succeeding
  via auto-retry. The Django README's "single-process only"
  caveat is finally truly obsolete.
- Multi-process foundation, phases 3-5 wrap-up: `free_head` joins
  the shm-resident counters so the free list works across
  processes (deletes / aborts in one process now actually let
  another process reuse the freed pages). `pager.begin` refreshes
  `header.free_head` from shm under the WRITER lock; commits store
  back. The on-disk header reflects the current value at next
  applyAndFinalize. README's "Concurrency model" rewritten to
  describe the SQLite-style single-writer / multi-reader /
  cross-process model that's now in place; the lock byte layout
  (RECOVERY at byte 2, WRITER at byte 0) is documented; tx style
  table updated to show that pessimistic / auto-commit txns hold
  the WRITER fcntl in addition to `db.mu`. Verified again at 8
  processes × 200 inserts → 1600 docs preserved every time.
- Multi-process foundation, phase 2C: fix the open-path race that
  was causing flaky `InvalidPageId` under 4+ concurrent first
  openers. Root cause: every fresh-init candidate (file_len == 0)
  raced to delete `.wal`/`.pyx-shm` and write the header, clobbering
  a process that had already moved on. Fix: take RECOVERY EXCL
  blocking at the start of `Pager.open`, do the fresh-init under
  it, downgrade to SHARED for the lifetime of the handle. SQLite
  uses essentially the same DMS pattern. New verification: 8
  processes × 100 inserts × 3 trials → 800 docs preserved every
  time, no errors. The Django example's "single-process only"
  caveat is now obsolete for the open-and-write pattern.
- Multi-process foundation, phase 1C: `src/flock.zig` POSIX byte-
  range advisory-lock wrapper, plus the Pager-side wiring:
  - WRITER lock (byte 0 of the data file) around `pager.begin` →
    `applyAndFinalize`/`abort`. One process at a time enters the
    commit pipeline across the whole machine.
  - RECOVERY lock (byte 2): on open, try non-blocking exclusive.
    If we get it, we're alone — seed shm from the on-disk header.
    Then downgrade to shared. If exclusive fails, another process
    is open; trust the live shm values. POSIX semantics release the
    locks on file-close.
  - Wal.open now reads the shm `walEndOffset` and trusts a non-zero
    value over its own local `file.length` read — so a fresh opener
    doesn't clobber an in-flight writer's append cursor.
  - **NOT yet sufficient for cross-process data preservation.**
    `header.btree_root` and the in-memory `page_cache` are still
    per-process: each process's commit updates its OWN btree_root
    (in-process), and `close`'s checkpoint writes that header to
    disk. If two processes commit and close, the last closer's
    btree_root overwrites the earlier one — earlier writes are lost.
    Phase 2 (wal-index in shm) is what makes cross-process writes
    actually durable. Until then, the multi-process safety story is
    "WAL appends won't corrupt and counters won't collide, but
    visibility across processes is still single-writer." The Django
    example's "single-process only" caveat stands.
- Multi-process foundation, phase 1B: the remaining three runtime
  counters move to shm — `num_pages`, `next_lsn`, and
  `wal.end_offset`. `Wal.open` takes the shm-resident
  `wal_end_offset` atomic and writes-through on every flush /
  reset / replay-truncate. `Pager.allocPage` allocates via
  `shm.numPages().fetchAdd`; `commitAppend` syncs the on-disk
  header from shm; `abort` rolls the shm page counter back to the
  txn-snapshot value. Single-process behaviour unchanged (84 tests
  green). Phase 1C adds the fcntl WRITER lock that makes
  cross-process commits safe.
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

[Unreleased]: https://github.com/parisxmas/pyx/compare/v0.3.0...HEAD
[0.3.0]: https://github.com/parisxmas/pyx/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/parisxmas/pyx/releases/tag/v0.2.0
