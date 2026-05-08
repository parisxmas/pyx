"""pyx — embeddable document database. Python binding.

    >>> import pyx
    >>> with pyx.Db.open("mydb.pyx") as db:
    ...     users = db.collection("users")
    ...     uid = users.insert({"name": "Alice", "age": 30})
    ...     print(users.get(uid))
    {'name': 'Alice', 'age': 30}

The library binary is loaded from one of (in order): the `PYX_LIBRARY` env
var, the package directory (post-install), the project's `zig-out/lib`
directory (development checkout). Build with `zig build` first.
"""
from __future__ import annotations

import ctypes as C
from contextlib import contextmanager
from typing import Iterator, Optional, Union

import random
import time

from . import _doc, _ffi
try:
    from . import _native as _native_mod  # type: ignore
except ImportError:
    _native_mod = None
from .errors import (
    PyxError,
    RetryBudgetExhausted,
    WriteConflict,
    from_status,
)

__all__ = [
    "Bound",
    "Collection",
    "Db",
    "OptimisticTxn",
    "PyxError",
    "RetryBudgetExhausted",
    "Snapshot",
    "TxnCollection",
    "WriteConflict",
    "format_version",
    "version",
]

ScalarValue = Union[None, bool, int, float, str]


def version() -> str:
    return _ffi.pyx_version_string().decode("utf-8")


def format_version() -> int:
    return int(_ffi.pyx_format_version())


def _check(rc: int) -> None:
    if rc < 0:
        msg = _ffi.pyx_last_error().decode("utf-8", errors="replace")
        raise from_status(rc, msg)


def _utf8(s: str) -> bytes:
    return s.encode("utf-8")


def _to_pyx_value(v: ScalarValue, pins: list) -> _ffi.PyxValue:
    """Convert a Python scalar to a `pyx_value`. `pins` keeps any bytes
    objects (for strings) alive across the C call — append everything you
    need to outlive the call to it."""
    val = _ffi.PyxValue()
    if v is None:
        val.type = _ffi.PYX_VAL_NULL
    elif isinstance(v, bool):
        val.type = _ffi.PYX_VAL_BOOL
        val.as_.boolean = 1 if v else 0
    elif isinstance(v, int):
        val.type = _ffi.PYX_VAL_I64
        val.as_.i64_v = v
    elif isinstance(v, float):
        val.type = _ffi.PYX_VAL_F64
        val.as_.f64_v = v
    elif isinstance(v, str):
        b = v.encode("utf-8")
        c_buf = (C.c_uint8 * len(b)).from_buffer_copy(b)
        pins.append(c_buf)
        val.type = _ffi.PYX_VAL_STRING
        val.as_.string.ptr = C.cast(c_buf, C.POINTER(C.c_uint8))
        val.as_.string.len = len(b)
    else:
        raise TypeError(f"unsupported indexed value type: {type(v).__name__}")
    return val


def _to_bound(v: Union[None, "Bound", "ScalarValue"], pins: list) -> Optional[_ffi.PyxBound]:
    """Convert None/scalar/Bound into a pyx_bound. None → no bound; a
    bare scalar is treated as `Bound.inclusive(scalar)` for the
    common case where users want a closed range without typing
    `Bound.inclusive(...)` twice."""
    if v is None:
        return None
    if not isinstance(v, Bound):
        # Bare scalar shorthand — defaults to inclusive.
        v = Bound.inclusive(v)
    b = _ffi.PyxBound()
    b.kind = v._kind
    if v._value is not None:
        b.value = _to_pyx_value(v._value, pins)
    return b


def _build_field_arrays(fields):
    """Build the (char**, size_t*) array pair for the compound-index C
    ABI. Returns the ctypes objects; both must outlive the C call. Each
    field is encoded as UTF-8 and stored in a list pinned by the
    returned ctypes arrays so the bytes survive."""
    n = len(fields)
    encoded = [f.encode("utf-8") for f in fields]
    ptr_arr = (C.c_char_p * n)(*encoded)
    len_arr = (C.c_size_t * n)(*[len(b) for b in encoded])
    return ptr_arr, len_arr


def _bounds_from_kwargs(
    gte=None, gt=None, lte=None, lt=None,
) -> tuple[Optional["Bound"], Optional["Bound"]]:
    """Build (lo, hi) Bounds from SQL-style kwargs.

    Exactly one of gte/gt may be set (lower bound); same for lte/lt
    (upper bound). Returns (None, None) for unbounded sides.
    """
    if gte is not None and gt is not None:
        raise TypeError("pass either gte= or gt=, not both")
    if lte is not None and lt is not None:
        raise TypeError("pass either lte= or lt=, not both")
    lo: Optional[Bound] = None
    if gte is not None:
        lo = Bound.inclusive(gte)
    elif gt is not None:
        lo = Bound.exclusive(gt)
    hi: Optional[Bound] = None
    if lte is not None:
        hi = Bound.inclusive(lte)
    elif lt is not None:
        hi = Bound.exclusive(lt)
    return lo, hi


class Bound:
    """Lower or upper bound for `find_range`.

    Use `Bound.inclusive(value)` or `Bound.exclusive(value)`. Pass None
    (or omit) for an unbounded side.
    """

    __slots__ = ("_kind", "_value")

    def __init__(self, kind: int, value: Optional[ScalarValue]):
        self._kind = kind
        self._value = value

    @classmethod
    def inclusive(cls, value: ScalarValue) -> "Bound":
        return cls(_ffi.PYX_BOUND_INCLUSIVE, value)

    @classmethod
    def exclusive(cls, value: ScalarValue) -> "Bound":
        return cls(_ffi.PYX_BOUND_EXCLUSIVE, value)


# ---------------------------------------------------------------------
# Db
# ---------------------------------------------------------------------

class Db:
    """A pyx database. Create with `Db.open(path)` (recommended via `with`)."""

    __slots__ = ("_handle",)

    def __init__(self, handle):
        self._handle = handle

    @classmethod
    def open(cls, path: str) -> "Db":
        out = C.c_void_p()
        rc = _ffi.pyx_open(path.encode("utf-8"), C.byref(out))
        _check(rc)
        return cls(out)

    def close(self) -> None:
        if self._handle:
            _ffi.pyx_close(self._handle)
            self._handle = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def __del__(self):
        self.close()

    def set_sync_mode(self, normal: bool = True) -> None:
        _ffi.pyx_set_sync_mode(self._handle, _ffi.PYX_SYNC_NORMAL if normal else _ffi.PYX_SYNC_FULL)

    def checkpoint(self) -> None:
        _check(_ffi.pyx_checkpoint(self._handle))

    @contextmanager
    def transaction(self) -> Iterator[None]:
        _check(_ffi.pyx_begin(self._handle))
        try:
            yield
        except Exception:
            _ffi.pyx_abort(self._handle)
            raise
        else:
            _check(_ffi.pyx_commit(self._handle))

    def collection(self, name: str) -> "Collection":
        return Collection(self, name)

    def create_collection(self, name: str) -> int:
        """Create a new collection backed by its own B+Tree. Idempotent —
        re-calling with an existing name returns the same id without
        allocating a new one. Returns the integer CollectionId.

        Default usage (without create_collection) keeps every collection
        in the shared default tree, which is backward-compatible with
        pre-sharding pyx. Calling create_collection opts a specific
        name into a separate tree, isolating its writes from the rest.

        Phase 2C limitation: indexes and run_optimistic don't yet
        understand non-default collections. CRUD via insert/get/delete
        works; create_index and run_optimistic on a created collection
        are phase 3 work.
        """
        nb = _utf8(name)
        out = C.c_uint32(0)
        _check(_ffi.pyx_create_collection(self._handle, nb, len(nb), C.byref(out)))
        return int(out.value)

    def snapshot(self) -> "Snapshot":
        out = C.c_void_p()
        _check(_ffi.pyx_snapshot_open(self._handle, C.byref(out)))
        return Snapshot(self, out)

    def create_index(self, collection: str, *fields: str) -> None:
        """Create a secondary index. Pass one field name for a single-
        field index or two-or-more for a compound index:

            db.create_index("users", "name")                  # single
            db.create_index("users", "last", "first")         # compound
        """
        if not fields:
            raise TypeError("create_index needs at least one field name")
        cb = _utf8(collection)
        if len(fields) == 1:
            fb = _utf8(fields[0])
            _check(_ffi.pyx_create_index(self._handle, cb, len(cb), fb, len(fb)))
            return
        ptrs, lens = _build_field_arrays(fields)
        _check(_ffi.pyx_create_compound_index(
            self._handle, cb, len(cb), ptrs, lens, len(fields),
        ))

    def drop_index(self, collection: str, *fields: str) -> None:
        if not fields:
            raise TypeError("drop_index needs at least one field name")
        cb = _utf8(collection)
        if len(fields) == 1:
            fb = _utf8(fields[0])
            _check(_ffi.pyx_drop_index(self._handle, cb, len(cb), fb, len(fb)))
            return
        ptrs, lens = _build_field_arrays(fields)
        _check(_ffi.pyx_drop_compound_index(
            self._handle, cb, len(cb), ptrs, lens, len(fields),
        ))

    def begin_optimistic(self) -> "OptimisticTxn":
        """Open an optimistic-concurrency transaction.

        Reads against the txn are lock-free; writes are buffered and
        applied at commit only after the read set validates. On a
        commit-time conflict, `WriteConflict` is raised — typically
        caught and retried via `Db.run_optimistic`.
        """
        out = C.c_void_p()
        _check(_ffi.pyx_begin_optimistic(self._handle, C.byref(out)))
        return OptimisticTxn(self, out)

    def run_optimistic(self, fn, max_attempts: int = 8) -> None:
        """Run `fn(txn)` inside an OCC transaction with auto-retry on
        `WriteConflict`. Sleeps with exponential backoff + full jitter
        between attempts (cap doubles from 100 µs up to 10 ms).

        Raises `RetryBudgetExhausted` if `max_attempts` is reached
        without success. Other exceptions from `fn` propagate after
        aborting the txn.
        """
        cap_ns = 100_000  # 100 µs
        max_ns = 10_000_000  # 10 ms
        for _ in range(max_attempts):
            txn = self.begin_optimistic()
            try:
                fn(txn)
            except BaseException:
                txn.abort()
                raise
            try:
                txn.commit()
                return
            except WriteConflict:
                sleep_ns = random.randrange(cap_ns) if cap_ns > 0 else 0
                if sleep_ns > 0:
                    time.sleep(sleep_ns / 1e9)
                cap_ns = min(cap_ns * 2, max_ns)
                continue
        raise RetryBudgetExhausted(_ffi.PYX_RETRY_BUDGET_EXHAUSTED, "OCC retry budget exhausted")


# ---------------------------------------------------------------------
# Collection
# ---------------------------------------------------------------------

def _doc_to_bytes(doc: dict) -> tuple[bytes, int]:
    b = _doc.encode(doc)
    arr = (C.c_uint8 * len(b)).from_buffer_copy(b)
    return arr, len(b)


def _read_buf(buf: _ffi.PyxBuf) -> dict:
    n = int(buf.len)
    if n == 0 or not buf.data:
        return {}
    raw = bytes(buf.data[:n])
    _ffi.pyx_buf_free(C.byref(buf))
    return _doc.decode(raw)


class Collection:
    __slots__ = ("_db", "_name", "_name_bytes")

    def __init__(self, db: Db, name: str):
        self._db = db
        self._name = name
        self._name_bytes = name.encode("utf-8")

    @property
    def name(self) -> str:
        return self._name

    def insert(self, doc: dict) -> int:
        arr, n = _doc_to_bytes(doc)
        out = C.c_uint64()
        _check(_ffi.pyx_insert(
            self._db._handle, self._name_bytes, len(self._name_bytes),
            arr, n, C.byref(out),
        ))
        return int(out.value)

    def put(self, doc_id: int, doc: dict) -> None:
        arr, n = _doc_to_bytes(doc)
        _check(_ffi.pyx_put(
            self._db._handle, self._name_bytes, len(self._name_bytes),
            doc_id, arr, n,
        ))

    def get(self, doc_id: int) -> Optional[dict]:
        buf = _ffi.PyxBuf()
        rc = _ffi.pyx_get(
            self._db._handle, self._name_bytes, len(self._name_bytes),
            doc_id, C.byref(buf),
        )
        if rc == _ffi.PYX_NOT_FOUND:
            return None
        _check(rc)
        return _read_buf(buf)

    def get_many(self, doc_ids) -> dict[int, dict]:
        """Look up many docs in one shot. Returns ``{doc_id: doc}`` for
        every id that's present (missing ids are simply absent from the
        result). Several times faster than calling ``get`` in a loop on
        the Python side because all the ctypes round-trips collapse into
        one. Order of `doc_ids` doesn't matter; duplicates are allowed
        but appear once in the result.

        Implementation: passes a packed (ids[], out_lens[], out_buf[])
        tuple to libpyx; the value bytes for each found id are written
        contiguously into out_buf in input order, with out_lens[i] = 0
        marking the misses. If the buffer is too small, libpyx returns
        the required size and we retry with a larger one.
        """
        ids = list(doc_ids)
        n = len(ids)
        if n == 0:
            return {}
        ids_arr = (C.c_uint64 * n)(*ids)
        out_lens = (C.c_uint32 * n)()
        cap = max(n * 256, 4096)  # heuristic: ~256 bytes/doc avg
        for _ in range(8):  # bounded retries — each pass either fits or doubles
            out_buf = (C.c_uint8 * cap)()
            used = C.c_size_t(0)
            rc = _ffi.pyx_get_many(
                self._db._handle, self._name_bytes, len(self._name_bytes),
                ids_arr, n, out_lens, out_buf, cap, C.byref(used),
            )
            if rc == _ffi.PYX_OK:
                break
            if rc == _ffi.PYX_BUFFER_TOO_SMALL:
                cap = max(used.value, cap * 2)
                continue
            _check(rc)
        else:
            raise RuntimeError("pyx_get_many: buffer-too-small loop did not converge")
        # Decode: values are packed in ids[] order; out_lens[i] = 0 for misses.
        # When the C extension (phase 5B) is available, do the entire
        # decode loop in C so we never enter Python-level decode at all.
        if _native_mod is not None:
            return _native_mod.decode_many(out_buf, out_lens, ids)
        result: dict[int, dict] = {}
        offset = 0
        mv = memoryview(out_buf).cast("B")
        for i in range(n):
            ln = out_lens[i]
            if ln == 0:
                continue
            result[ids[i]] = _doc.decode(bytes(mv[offset:offset + ln]))
            offset += ln
        return result

    def delete(self, doc_id: int) -> bool:
        rc = _ffi.pyx_delete(
            self._db._handle, self._name_bytes, len(self._name_bytes), doc_id,
        )
        if rc == _ffi.PYX_NOT_FOUND:
            return False
        _check(rc)
        return True

    def __iter__(self) -> Iterator[tuple[int, dict]]:
        return self._iter(snapshot_handle=None)

    def _iter(self, snapshot_handle) -> Iterator[tuple[int, dict]]:
        h = C.c_void_p()
        if snapshot_handle is None:
            _check(_ffi.pyx_iter_open(
                self._db._handle, self._name_bytes, len(self._name_bytes),
                C.byref(h),
            ))
        else:
            _check(_ffi.pyx_snapshot_iter_open(
                snapshot_handle, self._name_bytes, len(self._name_bytes),
                C.byref(h),
            ))
        try:
            while True:
                doc_id = C.c_uint64()
                buf = _ffi.PyxBuf()
                rc = _ffi.pyx_iter_next(h, C.byref(doc_id), C.byref(buf))
                if rc == _ffi.PYX_END:
                    return
                _check(rc)
                # buf borrows iterator-internal memory, valid until next call.
                # Decode to a dict (which copies) before yielding.
                if buf.len > 0 and buf.data:
                    raw = bytes(buf.data[: int(buf.len)])
                    yield int(doc_id.value), _doc.decode(raw)
        finally:
            _ffi.pyx_iter_close(h)

    def find_one(self, field=None, value=None, /, **kwargs) -> Optional[int]:
        """Indexed equality lookup. Two calling styles:

            users.find_one("name", "alice")                       # single-field
            users.find_one(last="smith", first="alice")           # compound

        Compound queries use kwargs in insertion order; the kwargs key
        sequence must match the field order of an existing compound
        index. Mixing positional and kwargs is an error.
        """
        if field is not None and kwargs:
            raise TypeError("find_one: pass either (field, value) or **kwargs, not both")
        if field is not None:
            return self._find_one_single(field, value)
        if kwargs:
            return self._find_one_compound(list(kwargs.keys()), list(kwargs.values()))
        raise TypeError("find_one needs (field, value) or **kwargs")

    def _find_one_single(self, field: str, value: ScalarValue) -> Optional[int]:
        pins: list = []
        v = _to_pyx_value(value, pins)
        out = C.c_uint64()
        cb = _utf8(field)
        rc = _ffi.pyx_find_one(
            self._db._handle, self._name_bytes, len(self._name_bytes),
            cb, len(cb), C.byref(v), C.byref(out),
        )
        del pins
        if rc == _ffi.PYX_NOT_FOUND:
            return None
        _check(rc)
        return int(out.value)

    def _find_one_compound(self, fields, values) -> Optional[int]:
        if not fields:
            raise TypeError("find_one needs at least one field")
        n = len(fields)
        ptrs, lens = _build_field_arrays(fields)
        pins: list = []
        val_arr = (_ffi.PyxValue * n)()
        for i, v in enumerate(values):
            val_arr[i] = _to_pyx_value(v, pins)
        out = C.c_uint64()
        rc = _ffi.pyx_compound_find_one(
            self._db._handle, self._name_bytes, len(self._name_bytes),
            ptrs, lens, n, val_arr, C.byref(out),
        )
        del pins
        if rc == _ffi.PYX_NOT_FOUND:
            return None
        _check(rc)
        return int(out.value)

    def find_range(
        self,
        field: str,
        lo=None,
        hi=None,
        *,
        gte=None, gt=None, lte=None, lt=None,
    ) -> Iterator[int]:
        """Indexed range scan. Two equivalent calling styles:

            # Positional, with bare scalars (defaults to inclusive):
            users.find_range("age", 18, 65)              # 18 ≤ age ≤ 65
            users.find_range("age", 18, None)            # 18 ≤ age
            users.find_range("age", Bound.exclusive(18)) # 18 <  age (mixed OK)

            # SQL-style kwargs:
            users.find_range("age", gte=18, lt=65)       # 18 ≤ age <  65
            users.find_range("age", gt=0)                #  0 <  age
        """
        if any(v is not None for v in (gte, gt, lte, lt)):
            if lo is not None or hi is not None:
                raise TypeError("mix of positional bounds and gte/gt/lte/lt kwargs")
            lo, hi = _bounds_from_kwargs(gte, gt, lte, lt)
        return self._range(field, lo, hi, snapshot_handle=None)

    def _range(
        self,
        field: str,
        lo,
        hi,
        snapshot_handle,
    ) -> Iterator[int]:
        cb = _utf8(field)
        pins: list = []
        lo_b = _to_bound(lo, pins)
        hi_b = _to_bound(hi, pins)
        h = C.c_void_p()
        if snapshot_handle is None:
            _check(_ffi.pyx_find_range(
                self._db._handle, self._name_bytes, len(self._name_bytes),
                cb, len(cb),
                C.byref(lo_b) if lo_b else None,
                C.byref(hi_b) if hi_b else None,
                C.byref(h),
            ))
        else:
            _check(_ffi.pyx_snapshot_find_range(
                snapshot_handle, self._name_bytes, len(self._name_bytes),
                cb, len(cb),
                C.byref(lo_b) if lo_b else None,
                C.byref(hi_b) if hi_b else None,
                C.byref(h),
            ))
        try:
            while True:
                out = C.c_uint64()
                rc = _ffi.pyx_lookup_next(h, C.byref(out))
                if rc == _ffi.PYX_END:
                    return
                _check(rc)
                yield int(out.value)
        finally:
            _ffi.pyx_lookup_close(h)


# ---------------------------------------------------------------------
# Snapshot — lock-free reads
# ---------------------------------------------------------------------

class Snapshot:
    """A point-in-time read-only view. Lock-free; safe to share across threads."""

    __slots__ = ("_db", "_handle")

    def __init__(self, db: Db, handle):
        self._db = db
        self._handle = handle

    def close(self) -> None:
        if self._handle:
            _ffi.pyx_snapshot_close(self._handle)
            self._handle = None

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        self.close()

    def __del__(self):
        self.close()

    def collection(self, name: str) -> "SnapshotCollection":
        return SnapshotCollection(self, name)


class SnapshotCollection:
    __slots__ = ("_snap", "_name", "_name_bytes")

    def __init__(self, snap: Snapshot, name: str):
        self._snap = snap
        self._name = name
        self._name_bytes = name.encode("utf-8")

    def get(self, doc_id: int) -> Optional[dict]:
        buf = _ffi.PyxBuf()
        rc = _ffi.pyx_snapshot_get(
            self._snap._handle, self._name_bytes, len(self._name_bytes),
            doc_id, C.byref(buf),
        )
        if rc == _ffi.PYX_NOT_FOUND:
            return None
        _check(rc)
        return _read_buf(buf)

    def __iter__(self) -> Iterator[tuple[int, dict]]:
        return self._snap._db.collection(self._name)._iter(self._snap._handle)

    def find_one(self, field: str, value: ScalarValue) -> Optional[int]:
        pins: list = []
        v = _to_pyx_value(value, pins)
        out = C.c_uint64()
        cb = _utf8(field)
        rc = _ffi.pyx_snapshot_find_one(
            self._snap._handle, self._name_bytes, len(self._name_bytes),
            cb, len(cb), C.byref(v), C.byref(out),
        )
        del pins
        if rc == _ffi.PYX_NOT_FOUND:
            return None
        _check(rc)
        return int(out.value)

    def find_range(
        self,
        field: str,
        lo=None,
        hi=None,
        *,
        gte=None, gt=None, lte=None, lt=None,
    ) -> Iterator[int]:
        if any(v is not None for v in (gte, gt, lte, lt)):
            if lo is not None or hi is not None:
                raise TypeError("mix of positional bounds and gte/gt/lte/lt kwargs")
            lo, hi = _bounds_from_kwargs(gte, gt, lte, lt)
        return self._snap._db.collection(self._name)._range(field, lo, hi, self._snap._handle)


# ---------------------------------------------------------------------
# Optimistic-concurrency transactions
# ---------------------------------------------------------------------

class OptimisticTxn:
    """Lock-free OCC transaction. Open via `Db.begin_optimistic` or
    `Db.run_optimistic`. Reads happen against an mmap'd snapshot;
    writes are buffered until commit, where validation checks every
    observed key against the live tree."""

    __slots__ = ("_db", "_handle")

    def __init__(self, db: Db, handle):
        self._db = db
        self._handle = handle

    def collection(self, name: str) -> "TxnCollection":
        return TxnCollection(self, name)

    def commit(self) -> None:
        if not self._handle:
            return
        rc = _ffi.pyx_optimistic_commit(self._handle)
        # The handle is destroyed on every outcome of commit.
        self._handle = None
        if rc == _ffi.PYX_WRITE_CONFLICT:
            raise WriteConflict(rc, "OCC write conflict — retry")
        _check(rc)

    def abort(self) -> None:
        if self._handle:
            _ffi.pyx_optimistic_abort(self._handle)
            self._handle = None

    def __enter__(self):
        return self

    def __exit__(self, exc_type, *_):
        # On exception: abort. On clean exit: caller is expected to
        # have called commit; if not, abort to be safe.
        if self._handle:
            self.abort() if exc_type is not None else self.commit()

    def __del__(self):
        # Don't raise from __del__; just release.
        if self._handle:
            _ffi.pyx_optimistic_abort(self._handle)
            self._handle = None


class TxnCollection:
    __slots__ = ("_txn", "_name", "_name_bytes")

    def __init__(self, txn: OptimisticTxn, name: str):
        self._txn = txn
        self._name = name
        self._name_bytes = name.encode("utf-8")

    def insert(self, doc: dict) -> int:
        arr, n = _doc_to_bytes(doc)
        out = C.c_uint64()
        _check(_ffi.pyx_optimistic_insert(
            self._txn._handle, self._name_bytes, len(self._name_bytes),
            arr, n, C.byref(out),
        ))
        return int(out.value)

    def put(self, doc_id: int, doc: dict) -> None:
        arr, n = _doc_to_bytes(doc)
        _check(_ffi.pyx_optimistic_put(
            self._txn._handle, self._name_bytes, len(self._name_bytes),
            doc_id, arr, n,
        ))

    def get(self, doc_id: int) -> Optional[dict]:
        buf = _ffi.PyxBuf()
        rc = _ffi.pyx_optimistic_get(
            self._txn._handle, self._name_bytes, len(self._name_bytes),
            doc_id, C.byref(buf),
        )
        if rc == _ffi.PYX_NOT_FOUND:
            return None
        _check(rc)
        return _read_buf(buf)

    def delete(self, doc_id: int) -> bool:
        rc = _ffi.pyx_optimistic_delete(
            self._txn._handle, self._name_bytes, len(self._name_bytes), doc_id,
        )
        if rc == _ffi.PYX_NOT_FOUND:
            return False
        _check(rc)
        return True

    def find_one(self, field: str, value: ScalarValue) -> Optional[int]:
        pins: list = []
        v = _to_pyx_value(value, pins)
        out = C.c_uint64()
        cb = _utf8(field)
        rc = _ffi.pyx_optimistic_find_one(
            self._txn._handle, self._name_bytes, len(self._name_bytes),
            cb, len(cb), C.byref(v), C.byref(out),
        )
        del pins
        if rc == _ffi.PYX_NOT_FOUND:
            return None
        _check(rc)
        return int(out.value)
