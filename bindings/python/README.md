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

    for doc_id in users.find_range("age",
                                   pyx.Bound.inclusive(18),
                                   pyx.Bound.exclusive(65)):
        print(doc_id, users.get(doc_id))

    with db.snapshot() as snap:
        snap_users = snap.collection("users")
        for doc_id, doc in snap_users:        # lock-free read
            print(doc_id, doc)
```

## Transactions

```python
with db.transaction():
    users.insert({"name": "Bob"})
    users.insert({"name": "Carol"})
# commits on normal exit, aborts on exception.
```

## Notes

- Python ints are encoded as i64; values outside the i64 range raise
  `ValueError`. Use floats for larger numbers.
- Indexed lookup values can be `None`, `bool`, `int`, `float`, or `str`.
- `Snapshot` reads are lock-free and safe to share across threads. The
  underlying `Db` is single-writer; serialize writes yourself if you call
  from multiple threads.
