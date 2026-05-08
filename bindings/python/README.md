# pyx — Python binding

Embeddable document database. ACID transactions, lock-free snapshots,
secondary indexes, range queries. Written in Zig, ~280 KB native lib,
loaded via `ctypes`.

## Install

For local development, build the native library first:

```sh
zig build -Doptimize=ReleaseSmall
```

Then point Python at the built artifact via `PYX_LIBRARY` (or just install
the package — `setup.py` / `pyproject.toml` will pick it up):

```sh
export PYX_LIBRARY=$(pwd)/zig-out/lib/libpyx.dylib   # macOS
export PYX_LIBRARY=$(pwd)/zig-out/lib/libpyx.so      # Linux
```

The package also auto-discovers `zig-out/lib` relative to the source
checkout, so this env var is only needed if the layout differs.

## Quick start

```python
import pyx

with pyx.Db.open("mydb.pyx") as db:
    db.set_sync_mode(normal=True)            # SQLite-WAL-NORMAL durability
    users = db.collection("users")
    uid = users.insert({"name": "Alice", "age": 30, "tags": ["admin"]})
    print(users.get(uid))                    # {'name': 'Alice', ...}

    db.create_index("users", "age")
    print(users.find_one("age", 30))         # uid

    # Range scan — three equivalent calling styles:
    list(users.find_range("age", 18, 65))                  # bare scalars (inclusive)
    list(users.find_range("age", gte=18, lt=65))           # SQL-style kwargs
    list(users.find_range("age",                           # explicit Bound (mixable)
                          pyx.Bound.inclusive(18),
                          pyx.Bound.exclusive(65)))

    with db.snapshot() as snap:
        snap_users = snap.collection("users")
        for doc_id, doc in snap_users:        # lock-free read
            print(doc_id, doc)
```

## Transactions (pessimistic — holds the data lock)

```python
with db.transaction():
    users.insert({"name": "Bob"})
    users.insert({"name": "Carol"})
# commits on normal exit, aborts on exception.
```

## Optimistic transactions

Lock-free reads, conflict-checked at commit, auto-retry with
exponential backoff + full jitter. Use this when multiple writer
threads need to overlap their read-and-then-write phases.

```python
def transfer(txn):
    accounts = txn.collection("accounts")
    src = accounts.get(src_id)
    dst = accounts.get(dst_id)
    accounts.put(src_id, {**src, "balance": src["balance"] - amount})
    accounts.put(dst_id, {**dst, "balance": dst["balance"] + amount})

db.run_optimistic(transfer)               # retries on WriteConflict

# Or manually:
with db.begin_optimistic() as txn:
    tc = txn.collection("c")
    cur = tc.get(5)
    tc.put(5, {**cur, "n": cur["n"] + 1})
    txn.commit()                          # raises WriteConflict on a race
```

`run_optimistic(fn, max_attempts=8)` retries on `pyx.WriteConflict`
until success or `pyx.RetryBudgetExhausted`. Backoff cap doubles
from 100 µs up to 10 ms; sleep is uniformly random in `[0, cap)`.

## Notes

- Python ints are encoded as i64; values outside the i64 range raise
  `ValueError`. Use floats for larger numbers.
- Indexed lookup values can be `None`, `bool`, `int`, `float`, or `str`.
- `Snapshot` reads and OCC reads are lock-free and safe to share
  across threads. Pessimistic writes (`Collection.put` etc.) serialize
  on an internal mutex; OCC writes overlap their read+work phase and
  serialize only at commit.
