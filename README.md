# pyx

An embeddable document database engine written in Zig. Single-file storage,
ACID transactions, lock-free MVCC snapshots, persistent secondary indexes,
and a stable C ABI so it can ship inside any host process — Python, Go, a
mobile app, an edge worker.

> **Status:** v0 / pre-1.0. The on-disk format is versioned and may still
> change between minor versions. Suitable for experimentation and embedded
> use cases where you control upgrades.

---

## Why another embedded DB?

Most embedded options force a choice:

- **SQLite** — bulletproof, but you serialise documents as blobs or shred
  them across relational tables yourself.
- **LMDB / RocksDB** — fast KV, no document model, no secondary indexes
  out of the box.
- **MongoDB-style document servers** — not embeddable; you run a process.

`pyx` aims for the SQLite niche but with a document-shaped API: insert
schemaless docs, look them up by id, build secondary indexes on field
paths, run range scans. The whole engine is ~10k lines of Zig and links as
a static or shared library (~280 KB stripped).

---

## Highlights

- **Single-file storage.** One database file (plus a sidecar WAL). No
  servers, no daemons.
- **CoW B+Tree.** Copy-on-write at the page level — snapshot isolation
  is a property of the data structure, not a layer on top.
- **WAL with crash recovery.** CRC-checked records, replayed on open.
  Durability is configurable: `full` (fsync every commit) or `normal`
  (fsync at checkpoint), the same trade-off as SQLite WAL.
- **Persistent secondary indexes.** `createIndex` / `dropIndex` survive
  reopen via an on-disk registry; auto-maintained on insert / put /
  delete. Equality (`findOne`, `findAll`) and range (`findRange`) lookups
  for string and i64 keys.
- **Lock-free MVCC snapshots.** Snapshots taken outside a transaction
  read directly from an `mmap`'d view of the file. Any number of reader
  threads can iterate, `findOne`, or `findRange` against the same
  snapshot concurrently with writers, with **zero mutex acquisition**
  on the read path.
- **Multi-op transactions.** `begin` / `commit` / `abort` from a single
  thread. Auto-commit ops on the same thread re-enter without
  deadlocking; other threads block until release.
- **C ABI.** Stable, versioned C header (`include/pyx.h`). Static and
  dynamic library targets in `zig-out/lib/`.
- **Python binding.** Pure-`ctypes`, no compilation required at install
  time. JSON-shaped `dict` in, `dict` out.

---

## Architecture in one diagram

```
                ┌──────────────────────────┐
   public API   │  Db / Collection         │   src/db.zig
                │  Snapshot / Iterator     │
                └────────────┬─────────────┘
                             │
                ┌────────────▼─────────────┐
   indexing    │  index.Manager           │   src/index.zig
                │  (registry + lookups)    │
                └────────────┬─────────────┘
                             │
                ┌────────────▼─────────────┐
   storage     │  CoW B+Tree              │   src/btree.zig
                └────────────┬─────────────┘
                             │
                ┌────────────▼─────────────┐
   pages + WAL │  Pager  ◀──▶  WAL        │   src/pager.zig, wal.zig
                └────────────┬─────────────┘
                             │
                       single .pyx file + .wal
```

A **single** B+Tree backs every collection and every index. The first byte
of each key disambiguates:

- `\x00` + varint(coll_len) + coll + u64_BE(doc_id) — primary doc entry
- `\x01` + ... + field + type_tag + value + u64_BE(doc_id) — index entry
- `\x02` + varint(coll_len) + coll + varint(field_len) + field — index
  registry entry

This keeps the engine small and means every lookup — primary or indexed
— shares the same tuned hot path.

---

## Quick start (Zig)

```zig
const std = @import("std");
const pyx = @import("pyx");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const ally = gpa.allocator();

    var db = try pyx.Db.open(ally, std.io, std.fs.cwd(), "mydb.pyx");
    defer db.close();

    const users = db.collection("users");

    // Build a doc with the binary builder.
    var b = pyx.doc.Builder.init(ally);
    defer b.deinit();
    try b.beginDocument();
    try b.putString("name", "alice");
    try b.putI64("age", 30);
    try b.endDocument();
    const bytes = try b.finish();
    defer ally.free(bytes);

    const id = try users.insert(bytes);

    try db.createIndex("users", "age");
    const got = try users.findOne("age", .{ .i64 = 30 });
    std.debug.assert(got.? == id);

    // Lock-free snapshot for readers.
    var snap = try db.snapshot();
    defer snap.deinit();
    var it = try snap.collection("users").iterator(ally);
    defer it.deinit();
    while (try it.next()) |entry| {
        std.debug.print("{d}: {} bytes\n", .{ entry.id, entry.doc.len });
    }
}
```

## Quick start (C)

```c
#include "pyx.h"

pyx_db *db = NULL;
if (pyx_open("mydb.pyx", &db) != PYX_OK) abort();

uint64_t id = 0;
pyx_insert(db, "users", 5, doc_bytes, doc_len, &id);

pyx_value v = { .type = PYX_VAL_I64, .as.i64 = 30 };
uint64_t found = 0;
if (pyx_find_one(db, "users", 5, "age", 3, &v, &found) == PYX_OK) {
    /* found has the doc id */
}

pyx_snapshot *snap = NULL;
pyx_snapshot_open(db, &snap);
/* ... lock-free reads from any thread ... */
pyx_snapshot_close(snap);

pyx_close(db);
```

The complete C surface is documented inline in
[`include/pyx.h`](include/pyx.h).

## Quick start (Python)

```python
import pyx

with pyx.Db.open("mydb.pyx") as db:
    db.set_sync_mode(normal=True)
    users = db.collection("users")

    uid = users.insert({"name": "alice", "age": 30, "tags": ["admin"]})
    print(users.get(uid))

    db.create_index("users", "age")
    print(users.find_one("age", 30))

    for doc_id in users.find_range(
        "age",
        pyx.Bound.inclusive(18),
        pyx.Bound.exclusive(65),
    ):
        print(doc_id, users.get(doc_id))

    with db.snapshot() as snap:
        for doc_id, doc in snap.collection("users"):  # lock-free
            print(doc_id, doc)
```

Multi-op transactions:

```python
with db.transaction():
    users.insert({"name": "bob"})
    users.insert({"name": "carol"})
# commits on normal exit, aborts on exception.
```

See [`bindings/python/README.md`](bindings/python/README.md) for install
notes.

---

## Building

Requires Zig **0.16.0** or newer.

```sh
# library + CLI
zig build -Doptimize=ReleaseFast

# run all tests (Zig unit + C-ABI)
zig build test

# benchmarks
zig build bench                       # pyx single-thread profile
zig build bench-concurrent            # pyx readers vs writer
zig build bench-sqlite                # SQLite comparison
zig build bench-concurrent-sqlite     # SQLite readers vs writer
zig build bench-writer-profile        # for sample(1) / Instruments
zig build bench-reader-profile
```

Build artefacts:

| Path                                | What                          |
|-------------------------------------|-------------------------------|
| `zig-out/bin/pyx`                   | demo CLI (prints version)     |
| `zig-out/bin/pyx-bench*`            | benchmark binaries            |
| `zig-out/lib/libpyx.a`              | static library                |
| `zig-out/lib/libpyx.{dylib,so}`     | dynamic library               |
| `zig-out/include/pyx.h`             | public C header               |

The SQLite-comparison benchmarks expect a Homebrew SQLite at
`/opt/homebrew/Cellar/sqlite/3.53.0`; edit `build.zig` if you have it
elsewhere.

---

## Concurrency model

The model is intentionally simple:

| Operation                         | Lock?               | Multi-thread?              |
|-----------------------------------|---------------------|----------------------------|
| Auto-commit `insert`/`put`/`delete` | internal mutex       | yes (serialised)           |
| Explicit `begin`/`commit`         | held until commit   | single thread per txn      |
| `Collection.iterator`             | mutex during open   | one thread per iterator    |
| `Snapshot` (taken outside a txn)  | **none on reads**   | **N readers, lock-free**   |
| `Snapshot.findOne` / `findRange`  | **none**            | **N readers, lock-free**   |

Snapshot reads bypass the page cache and pager state entirely — they
`memcpy` from an `mmap`'d region (or fall back to `pread`, which POSIX
guarantees is thread-safe per fd). Because the B+Tree is copy-on-write,
pages reachable from the captured root are never mutated; writers append
new pages past the snapshot's mapped length.

The current engine is **single-writer**. Concurrent auto-commit writes
from many threads are correct (they serialise on the mutex), but they do
not parallelise. Multi-writer is a v1 work item.

---

## Benchmarks vs SQLite

Numbers below are from the bundled benchmark harnesses
(`src/bench*.zig`) compiled with `-Doptimize=ReleaseFast`. Both engines
use the same workload, document size, and durability setting; pyx is in
its `normal` sync mode (fsync at checkpoint) and SQLite is in
`journal_mode=WAL, synchronous=NORMAL` — the apples-to-apples baseline.
SQLite's default rollback-journal numbers are included for reference.

**Test environment:** Apple M4 (10 cores), 24 GB RAM, macOS 26.3,
APFS on internal SSD, Zig 0.16.0, SQLite 3.53.0 (Homebrew).

### Single-thread microbench — 10 000 ops

| Operation               | pyx (normal) | SQLite WAL+NORMAL | SQLite default | pyx vs WAL |
|-------------------------|-------------:|------------------:|---------------:|-----------:|
| insert (auto-commit)    | **261 k/s**  | 115 k/s           |  5.5 k/s       | **2.3×**   |
| insert (batched in txn) | **4.01 M/s** | 3.30 M/s          |  2.84 M/s      | **1.2×**   |
| random `get` by id      | **3.10 M/s** | 1.27 M/s          |  357 k/s       | **2.4×**   |
| full collection iterate | **233 M docs/s** | 32 M docs/s    |  32 M docs/s   | **7.3×**   |
| indexed `findOne`       | **1.40 M/s** | 1.24 M/s          |  357 k/s       | **1.1×**   |

`zig build bench` / `zig build bench-sqlite` to reproduce.

### Concurrent — 100 k preloaded docs, 3 s per phase

**Read-only** (each reader holds a snapshot; 75 % random `get`, 25 %
indexed point query):

| Threads | pyx aggregate | SQLite WAL aggregate | pyx advantage |
|---------|--------------:|---------------------:|--------------:|
| 1       | 1.40 M ops/s  | 716 k ops/s          | 1.9×          |
| 2       | 2.75 M ops/s  | 1.02 M ops/s         | 2.7×          |
| 4       | 5.40 M ops/s  | 849 k ops/s          | 6.4×          |
| 8       | **7.69 M ops/s** | 328 k ops/s        | **23×**       |

pyx scales near-linearly because snapshot reads are lock-free and
mmap-backed. SQLite's WAL reader path serialises on the wal-index
shared-memory mutex, so read throughput peaks at two threads and
degrades past four.

**1 writer + N readers** (writer does 100-doc batched inserts):

| Phase    | pyx writer        | pyx readers   | SQLite writer | SQLite readers |
|----------|------------------:|--------------:|--------------:|---------------:|
| 1w + 1r  | 624 k inserts/s   | 884 k ops/s   | 660 k inserts/s | 613 k ops/s  |
| 1w + 2r  | 312 k inserts/s   | 2.61 M ops/s  | 353 k inserts/s | 661 k ops/s  |
| 1w + 4r  | 271 k inserts/s   | 4.07 M ops/s  | 147 k inserts/s | 564 k ops/s  |
| 1w + 8r  | **243 k inserts/s** | **5.40 M ops/s** | **44 k inserts/s** | **332 k ops/s** |

Under concurrent read pressure, pyx's writer holds steady around
240 k inserts/s while SQLite's collapses to 44 k. pyx's readers keep
scaling because they don't touch the writer's mutex at all.

`zig build bench-concurrent` / `zig build bench-concurrent-sqlite` to
reproduce.

### Caveats

- These are microbenchmarks. The workload is small documents (~30 B
  each) and a single collection — useful for comparing engine cost,
  not for projecting application performance.
- macOS APFS `fsync` semantics differ from Linux `ext4`/`xfs`; absolute
  numbers will move on Linux, but the relative shape (lock-free
  snapshot reads vs WAL-index contention) is the same.
- pyx is single-writer; SQLite is also effectively single-writer in
  WAL mode. The 1w+Nr numbers measure that case fairly. Multi-writer
  is not yet implemented in pyx.
- The auto-commit insert path fsyncs less often in `normal` mode,
  matching SQLite's `synchronous=NORMAL`. With pyx's default
  `full` mode (fsync per commit), auto-commit insert drops by roughly
  4–6× — comparable to SQLite default rollback-journal mode.

## Project layout

```
src/
  root.zig          public Zig module (re-exports)
  main.zig          tiny CLI binary
  db.zig            Db / Collection / Snapshot / Iterator
  btree.zig         CoW B+Tree
  pager.zig         page cache, file I/O, sync modes
  wal.zig           write-ahead log + replay
  doc.zig           binary doc format, Builder
  json.zig          JSON ↔ doc bridge
  index.zig         secondary index manager
  c_api.zig         stable C ABI (drives include/pyx.h)
  bench*.zig        benchmark harnesses

include/pyx.h       C header — versioned ABI

bindings/python/    ctypes-based Python wrapper
  pyx/              package source
  tests/            pytest suite
  pyproject.toml    PEP 517 build config

build.zig           build graph (lib, exe, tests, benches)
```

---

## Testing

```sh
zig build test
```

The test step runs:

- Module-level Zig unit tests in every `src/*.zig` (open/insert/get,
  reopen persistence, snapshot isolation, indexed equality and range
  scans, multi-thread concurrent inserts, lock-free snapshot reads under
  concurrent writes).
- The C-ABI test module in `src/c_api.zig`.

Python tests live under `bindings/python/tests/` and are run with
`pytest` after building the native lib.

---

## Roadmap

- [ ] Multi-writer (per-page locks or group commit).
- [ ] Compound indexes.
- [ ] Streaming `findRange` paging cursor in the C ABI.
- [ ] Background checkpointer.
- [ ] On-disk format compatibility guarantee at v1.
- [ ] More language bindings (Go, Node, Swift).

---

## License

Apache License 2.0 — see [LICENSE](LICENSE). Copyright © 2026 Baris Akin.
