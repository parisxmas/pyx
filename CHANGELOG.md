# Changelog

All notable changes to pyx are recorded here. Format roughly follows
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); each release
is grouped under its version. Pre-release work since the most recent
tag goes under `## Unreleased`.

## Unreleased

### Added
- Phase 6: **batched insert API** + **native encode**.

  `Collection.insert_many(docs)` wraps N inserts in one
  transaction — single per-collection WRITER fcntl, single WAL
  flush, single fsync. C ABI:

      pyx_insert_many(db, coll, len, docs_buf, docs_buf_len,
                      doc_lens, n_docs, out_ids)

  Caller passes a packed `docs_buf` (concatenated encoded docs)
  plus a `doc_lens[n_docs]` array; libpyx slices internally and
  feeds them to `Collection.insertMany` which assigns ids and
  performs the single-commit cycle.

  Pure-Zig insert_many alone gives a ~18× speedup vs `insert` in
  a loop, but profiling showed `_doc.encode` at 74% of the
  remaining time. Phase 6 adds **native encode** to `_native.c`:

      _native.encode(doc) -> bytes
      _native.encode_many(docs) -> (bytes, list[int])

  `encode_many` builds one packed bytes buffer + a per-doc lens
  list in a single C call — Python `insert_many` feeds those
  straight into ctypes via `from_buffer_copy`, no per-doc
  encode loop. `_doc.encode` also routes through native when
  available, so single-doc `insert` benefits too.

  OverflowError → ValueError translation in the C encoder so
  i64-range checks match the pure-Python encoder's behaviour.

  Bench delta (5000-doc bulk insert):

      W1  seq inserts:          31 kops/s   (unchanged — autocommit)
      W1b zig-only insert_many:    534 kops/s   (vs SQLite 3.06 Mops/s)
      W1b + native encode_many:  1830 kops/s   (vs SQLite 3.00 Mops/s,
                                               ratio 0.61x)

  Final pyx-vs-sqlite ratios:
      W1  seq inserts:    0.87x
      W1b bulk insert:    0.61x   ← phase 6
      W2  random reads:   0.43x
      W2b batched reads:  0.63x
      W3  multi-coll:     1.57x   (pyx faster — phase 3 win)
      W4  shared coll:    1.09x

  41 Python tests still pass.

- Phase 5A: **sorted-scan in `Collection.getMany`**. Above 128 ids per
  call the implementation sorts the input ids, opens a single
  iterator at the smallest id's encoded key, and walks forward
  through the leaves matching against remaining sought ids — one
  descent + one leaf-chain walk instead of N independent descents.
  Bounded by the collection's primary-key prefix so it never wanders
  into index pages or the catalog. Below 128 ids the descent path
  still wins (random ids spread across the tree force the iterator
  to skip too many entries between matches), so `getMany` picks
  between `getManyDescents` and `getManySorted` based on
  `ids.len < 128`. Threshold is empirical; re-tune for differently
  shaped trees.

  Bench (20k random reads against 10k-doc tree):

      batch=  16    63.4 ms    315 k/s   1.54x  (descent path)
      batch=  64    61.2 ms    326 k/s   1.60x  (descent path)
      batch= 256    34.5 ms    580 k/s   1.94x  (sorted-scan)
      batch=1024    36.4 ms    549 k/s   2.68x  (sorted-scan)
      batch=4096    29.2 ms    685 k/s   3.35x  (sorted-scan)

  Also a small `_doc.py` micro-opt — pre-compiled `struct.Struct`
  unpackers for i64/f64/u32 instead of `int.from_bytes`. Marginal
  effect on the bench docs (which have few numeric fields), but
  still strictly faster.

- Phase 5B: **native document decode**. New Python C extension
  `pyx._native` (sources at `bindings/python/pyx/_native.c`)
  that replaces `_doc.decode` and the per-value decode loop in
  `Collection.get_many` with a tight C parser that builds
  `dict`/`list`/`int`/`float`/`str`/`bytes` directly via the
  Python C API — no Python-level interpreter loop on the hot
  path. Two functions exported:

      _native.decode(buf)               -> dict
      _native.decode_many(buf, lens, ids) -> dict[int, dict]

  The `decode_many` path lets `Collection.get_many` skip the
  Python-side unpacking entirely: pyx_get_many populates the
  shared `out_buf` + `out_lens` ctypes arrays, the C extension
  walks them once and returns the finished dict.

  Build is wired into `bindings/python/setup.py` as a setuptools
  `Extension` with `optional=True` — if the C compiler isn't
  available, the wheel still builds and the binding falls back
  to the pure-Python `_doc.decode` at import time. The old
  `BdistWheel.get_tag` override (which forced `py3-none`) is
  gone; setuptools now picks the right Python-version-specific
  tag because the package has a real C extension.

  Bench (20k random reads against 10k-doc tree):

      loop  c.get(id):                       332 kops/s   (was 212 — +56%)
      batch c.get_many(256):               1538 kops/s   (was 580 — +165%)
      batch c.get_many(1024):              1602 kops/s   (was 549 — +192%)
      batch c.get_many(4096):              1775 kops/s   (was 685 — +159%)

  Side-by-side vs SQLite at batch=256:

      pyx     1.54 Mops/s
      sqlite  2.31 Mops/s
      ratio   0.67x   (was 0.24x with phase 5A only)

  41 existing Python tests still pass; pure-Python decode round-trip
  matches native decode byte-for-byte across the test corpus.

- Phase 4 of the post-0.4.0 work: **batched-get API**.
  `Collection.get_many(ids) -> {id: doc}` issues one ctypes call
  for any number of doc ids and decodes the results in input
  order. The C ABI is `pyx_get_many(db, coll, ids[], n_ids,
  out_lens[], out_buf, out_buf_cap, *out_buf_used)` — values
  are packed into a caller-allocated buffer; if the buffer is
  too small, libpyx returns the required size and the Python
  wrapper retries with `max(used, cap*2)`. New status code
  `PYX_BUFFER_TOO_SMALL = -14`.

  Measured ~1.5× speedup on random-read workloads at any batch
  size ≥ 16; the remaining gap to SQLite's `WHERE id IN (…)` on
  this benchmark is per-id tree descents (each `get` walks the
  tree from root) and per-value Python decode, not ctypes
  overhead. Sorted-scan + native decode are phase 5 candidates.

- Keyspace sharding, phase 3: **per-collection writer locks**.
  Two processes (or two `Db` handles) committing to *different*
  collections no longer block each other on the cross-process
  WRITER fcntl. New byte-region layout:
    - byte  0    : open serializer + checkpoint (stop-the-world)
    - byte  8    : WAL append serializer (held briefly during
                   `wal.flush`, refreshes `end_offset` from shm under
                   the lock so two parallel committers can't pwrite
                   at the same offset)
    - bytes 16+i : per-collection commit lock (held during
                   `begin → applyAndFinalize`)
  `Pager.begin(collection_id)` takes the per-collection byte;
  `applyAndFinalize` releases it and publishes ONLY that
  collection's slot in shm (writing all slots back, as phase 2B
  did, would clobber a parallel writer's progress).
  `Pager.checkpoint` stops the world via byte 0 + byte 8.
  `Db.beginForCollection(cid)` exposes the per-collection variant
  to OCC; `OptimisticTxn.commit` picks the writer lock based on
  the collection it modified (single-collection only — cross-
  collection OCC stays a phase 4 limitation).

  Sharding phase 3 also disables free-list reuse for non-default
  collections — `allocPageInner` always extends the file via
  `shm.numPages.fetchAdd` for those, and `freePageInner` is a no-op.
  Reason: the existing free-list machinery uses per-process
  `header.free_head` which would race under parallel commits.
  Default-tree behaviour is unchanged (single-writer-at-a-time
  on byte 16+0, free list reused as before). Trade-off:
  non-default collections leak pages on delete; data file grows.
  Phase 4 will add cross-process-safe per-collection free lists.

  COMPAT NOTE: v0.4.0 used byte 0 for the entire commit pipeline.
  v0.5.0 commits to bytes 16+i. **Mixing v0.4.0 and v0.5.0
  processes on the same DB is unsafe** — they would not block
  each other on commit. Upgrade everything together.

  Tests: 97/97 still pass. Phase-3-specific multi-process
  benchmark coming alongside the release in `bench/`.

### Fixed
- Sharding: indexes on created collections actually work now. The
  0.4.0 limitation was that `createIndex` / `createCompoundIndex`
  scanned the **default** tree for docs to index and wrote entries
  there too, so a `findOne` on a created collection always missed
  (no entries had been built; the docs lived in the per-collection
  tree). Threaded `CollectionId` through every public method of
  `Indexes.Manager` (`createIndex`, `dropIndex`,
  `createCompoundIndex`, `dropCompoundIndex`, `afterInsert`,
  `beforeDelete`, `findOne`, `findOneCompound`, `findRange`,
  `findAll`); the registry stays in the default tree (one global
  registry of "what indexes exist") but index entries now live in
  the same tree as the docs they index. So a snapshot of a
  collection is internally consistent w.r.t. its own indexes.
  Also fixed a pre-existing double-free in `createIndex` /
  `createCompoundIndex` — `errdefer def.deinit` stayed active
  after `self.indexes.append` took ownership; reordered append
  to the end so the errdefer covers only its own allocations.
- Sharding: while we're at it, also verified that **OCC on a
  created collection already works** in 0.4.0. The phase 2C
  release notes called it out as broken, but it isn't: every
  read/write inside an `OptimisticTxn` routes through
  `db.collection(name)` / `snapshot.collection(name)`, both of
  which consult the catalog cache and resolve to the right id.
  New test `phase 2C limitations: OCC on a created collection
  — does it actually break?` passes with no code change.

## 0.4.0 — 2026-05-08

The headline of 0.4.0 is **keyspace sharding** — opt-in, per-name
isolated B+Trees in a single `.pyx` file. Calling
`db.create_collection("foo")` allocates a fresh `CollectionId`,
persists a `name → id` mapping in the on-disk catalog, and from
that point on `db.collection("foo")` reads and writes through
its own tree, isolated from every other collection.

The infrastructure is the load-bearing piece: `CollectionId`
threaded through every layer (pager → WAL → btree → catalog →
snapshot), per-collection roots in shm + on-disk header v2,
WAL V2 records carrying a `collection_id` per put/delete,
snapshot capturing all in-use roots atomically, and a catalog
cache that survives close/reopen + a fully-wiped shm.

The throughput payoff — per-collection writer locks so N
writers across N collections can commit in parallel — is
**not in 0.4.0**; that's phase 3, deferred to 0.5.0. Every
commit still serialises on the global single-writer protocol
that 0.3.0 shipped (one machine-wide WRITER fcntl + one
in-process `db.mu`). Expect 0.4.0's write throughput to match
0.3.0's; the win is feature scope, not commits/s.

### Added
- Keyspace sharding, phase 2C: the user-facing API. Calling
  `db.create_collection("foo")` (Python) / `db.createCollection("foo")`
  (Zig) / `pyx_create_collection(...)` (C) allocates the next free
  shm slot, persists a `name → CollectionId` mapping in the default
  tree's catalog (`\x05`-prefixed key), and from then on
  `db.collection("foo")` resolves to that id and operations route
  through that collection's own B+Tree. Idempotent — re-calling
  with an existing name returns the same id without writing.
  - **In-memory cache**: `Db.collections: StringHashMap(CollectionId)`,
    populated at open by scanning `\x05`-prefixed entries in the
    default tree and freed at close. Cache lookup keeps
    `db.collection(name)` O(1).
  - **Catalog scan also reseeds shm**: every id found in the catalog
    has its slot marked in_use, so a process whose shm got wiped
    (machine reboot) recovers the live state purely from the on-disk
    catalog + header. `Db.createCollection` allocates the lowest
    free slot starting at 1 (slot 0 reserved for the default tree).
  - **Snapshot multi-root**: `Snapshot` now captures every in-use
    collection's root atomically, in `btree_roots[max_collections]`.
    `Snapshot.collection(name)` consults the catalog cache to pick
    the right slot; `SnapshotCollection.view()` uses `btree_roots[id]`.
    `btree_root` (singular) stays as a mirror of slot 0 so OCC's
    `start_root` and pre-2C call sites still work.
  - **C ABI**: `pyx_create_collection(db, name, len, *out_id)` —
    new export, status code returned.
  - **Python**: `Db.create_collection(name) -> int`, alongside the
    existing `Db.collection(name)` which now consults the catalog.
  - Three new tests: id allocation + idempotency, catalog survives
    close/reopen + lost shm (rebuilt purely from on-disk default
    tree), and isolation between default and created collections
    (including snapshot routing).
  - **Phase 2C limitations** (deferred to phase 3):
    - `createIndex` on a created collection writes the index
      machinery to the default tree, so index-backed lookups on
      that collection won't find anything. Use the default
      collection if you need indexes today.
    - `runOptimistic` validates against the default tree's root
      only — OCC for created collections is broken.
    Plain CRUD (`insert` / `get` / `delete`) and lock-free
    snapshot reads through `Snapshot.collection(name).get(id)`
    work correctly for created collections.

- Keyspace sharding, phase 2B: actual per-collection tree routing,
  end to end. No public API yet — `Db.collection(name)` still
  resolves every name to the default tree — but every layer below
  it now respects the `CollectionId` plumbed through phase 1, and
  per-collection trees are correctly persisted, replayed, and
  reseeded into a fresh shm.
  - **Disk format bumps to version 2.** Header gains a
    `collection_roots[max_collections]` array (64 bytes) so each
    tree's root rides through close/reopen without depending on
    shm. v1 files still open: the deserializer detects
    `version == 1`, infers `collection_roots[0] = btree_root`,
    and leaves higher slots zero. v2 writes always go through
    new code; v0.3.0 binaries can no longer open v2 files.
  - **WAL gets V2 record types.** `put_v2 (4)` and
    `delete_v2 (5)` carry a `varint collection_id` prefix in the
    body; legacy `put (1)` / `delete (2)` records are still
    parsed during replay (implicit collection_id = 0). All new
    writes emit V2 records; the recovery path dispatches each
    op to `BTree.init(allocator, pager, p.collection_id)`.
  - **`Pager.bTreeRoot(id)` / `Pager.setBTreeRoot(id, root)`**
    actually route per-id. In-txn reads/writes go through the
    in-process `header.collection_roots[id]` array;
    out-of-txn reads return `shm.collectionRoot(id)`.
    `Pager.recordPut` and `Pager.recordDelete` now take a
    `CollectionId`; `BTree` forwards its own `self.collection_id`
    on every call.
  - **`pager.begin` refreshes all per-id roots from shm** under
    the WRITER lock; `applyAndFinalize` publishes every slot
    back. `shm.seedFromHeader` takes the full
    `collection_roots[]` slice and fans it out across slots,
    and marks any slot with a non-zero on-disk root as in-use —
    so a process whose shm got wiped (machine reboot) can
    recover the live state purely from the data file's header.
  - Two new sharding tests in `src/btree.zig` exercise the new
    routing without going through the still-default `Db` API:
    one verifies key isolation across `BTree.init(..., id=0)`
    vs `BTree.init(..., id=5)`; another simulates a reboot by
    deleting `-shm` + `.wal` between sessions and confirms
    both trees come back with the right contents purely from
    the on-disk header.
  - 92/92 tests pass; Python binding round-trip still clean.
    Phase 2C will wire up the public-facing
    `Db.createCollection` API + on-disk name→id catalog +
    snapshot/index updates that depend on knowing which id a
    given collection name belongs to.

- Keyspace sharding, phase 2A: `shm.zig` reserves a 16-slot
  `collections[]` array (256 bytes after the existing fields, well
  inside the 4 KB `-shm` reservation). Each slot carries a
  per-collection `btree_root`, `free_head`, and `in_use` byte;
  accessor methods (`collectionRoot`, `collectionFreeHead`,
  `collectionInUse`, `setCollectionInUse`) wrap the atomic loads
  and stores. `seedFromHeader` mirrors the top-level root/free_head
  into slot 0 and marks it in-use, so the default tree always has
  a valid slot. Pager.open also re-seeds slot 0 idempotently when
  it sees a legacy shm (magic+version match, but `collections[]`
  is still all zeros). Pure infrastructure — no public API change,
  no behavioural change; phase 2B will start routing per-id reads
  through these slots and adding the on-disk catalog that maps
  collection name → id.

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

[Unreleased]: https://github.com/parisxmas/pyx/compare/v0.4.0...HEAD
[0.4.0]: https://github.com/parisxmas/pyx/compare/v0.3.0...v0.4.0
[0.3.0]: https://github.com/parisxmas/pyx/compare/v0.2.0...v0.3.0
[0.2.0]: https://github.com/parisxmas/pyx/releases/tag/v0.2.0
