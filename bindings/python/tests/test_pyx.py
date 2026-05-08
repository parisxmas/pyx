"""Smoke tests for the pyx Python binding.

Run with: `python -m pytest bindings/python/tests/`
The tests find `libpyx` via PYX_LIBRARY or auto-discovery from
`zig-out/lib`. Build first: `zig build -Doptimize=ReleaseSmall`.
"""
from __future__ import annotations

import os
import threading
from pathlib import Path

import pytest

import pyx
from pyx import _doc


# --------------------------------------------------------------------
# Doc codec round-trip — pure Python, doesn't need the native lib.
# --------------------------------------------------------------------

class TestDocCodec:
    def test_scalars(self):
        d = {
            "n": None,
            "t": True,
            "f": False,
            "i": 42,
            "neg": -7,
            "x": 3.14,
            "s": "hello",
            "b": b"\x00\x01\x02",
        }
        assert _doc.decode(_doc.encode(d)) == d

    def test_nested(self):
        d = {
            "user": {
                "name": "Alice",
                "tags": ["admin", "early-adopter"],
                "scores": [1, 2.5, None, True, [1, 2, 3]],
                "meta": {"k": "v"},
            },
        }
        assert _doc.decode(_doc.encode(d)) == d

    def test_empty(self):
        assert _doc.decode(_doc.encode({})) == {}

    def test_unicode(self):
        d = {"emoji": "héllo 中文", "keyÿ": "v"}
        assert _doc.decode(_doc.encode(d)) == d

    def test_int_overflow(self):
        with pytest.raises(ValueError):
            _doc.encode({"n": 2**63})

    def test_top_level_must_be_dict(self):
        with pytest.raises(TypeError):
            _doc.encode([1, 2, 3])  # type: ignore[arg-type]


# --------------------------------------------------------------------
# Native binding tests — touch the dynamic library.
# --------------------------------------------------------------------

@pytest.fixture
def db_path(tmp_path: Path) -> str:
    return str(tmp_path / "test.pyx")


@pytest.fixture
def db(db_path):
    with pyx.Db.open(db_path) as h:
        yield h


class TestLifecycle:
    def test_version(self):
        assert pyx.format_version() >= 1
        assert isinstance(pyx.version(), str) and pyx.version()

    def test_open_close(self, db_path):
        d = pyx.Db.open(db_path)
        d.close()
        d.close()  # idempotent

    def test_reopen(self, db_path):
        with pyx.Db.open(db_path) as d:
            users = d.collection("users")
            uid = users.insert({"name": "Alice"})
        with pyx.Db.open(db_path) as d:
            assert d.collection("users").get(uid) == {"name": "Alice"}


class TestCrud:
    def test_insert_get(self, db):
        users = db.collection("users")
        uid = users.insert({"name": "Alice", "age": 30})
        assert users.get(uid) == {"name": "Alice", "age": 30}

    def test_get_missing(self, db):
        assert db.collection("users").get(999) is None

    def test_put_overwrites(self, db):
        users = db.collection("users")
        uid = users.insert({"name": "Alice"})
        users.put(uid, {"name": "Alicia"})
        assert users.get(uid) == {"name": "Alicia"}

    def test_delete(self, db):
        users = db.collection("users")
        uid = users.insert({"name": "Bob"})
        assert users.delete(uid) is True
        assert users.delete(uid) is False
        assert users.get(uid) is None

    def test_iteration(self, db):
        users = db.collection("users")
        ids = [users.insert({"i": i}) for i in range(5)]
        seen = dict(users)
        assert set(seen.keys()) == set(ids)
        assert all(seen[ids[i]] == {"i": i} for i in range(5))


class TestTransactions:
    def test_explicit_commit(self, db):
        users = db.collection("users")
        with db.transaction():
            uid = users.insert({"name": "Alice"})
        assert users.get(uid) == {"name": "Alice"}

    def test_abort_on_exception(self, db):
        users = db.collection("users")
        with pytest.raises(RuntimeError):
            with db.transaction():
                users.insert({"name": "Aborted"})
                raise RuntimeError("boom")
        assert list(users) == []


class TestIndex:
    def test_find_one(self, db):
        users = db.collection("users")
        uid = users.insert({"name": "Alice", "age": 30})
        users.insert({"name": "Bob", "age": 25})
        db.create_index("users", "age")
        assert users.find_one("age", 30) == uid
        assert users.find_one("age", 999) is None

    def test_find_range(self, db):
        users = db.collection("users")
        ids = {users.insert({"age": age}): age for age in (18, 25, 30, 40, 65)}
        db.create_index("users", "age")
        # [25, 40) → ages 25, 30
        out = list(users.find_range("age",
                                    pyx.Bound.inclusive(25),
                                    pyx.Bound.exclusive(40)))
        ages = sorted(ids[i] for i in out)
        assert ages == [25, 30]

    def test_string_index(self, db):
        users = db.collection("users")
        uid = users.insert({"name": "Alice"})
        users.insert({"name": "Bob"})
        db.create_index("users", "name")
        assert users.find_one("name", "Alice") == uid

    def test_drop_index(self, db):
        users = db.collection("users")
        users.insert({"age": 30})
        db.create_index("users", "age")
        db.drop_index("users", "age")
        with pytest.raises(pyx.PyxError):
            users.find_one("age", 30)


class TestSnapshot:
    def test_snapshot_isolates(self, db):
        users = db.collection("users")
        uid = users.insert({"v": 1})
        with db.snapshot() as snap:
            users.put(uid, {"v": 2})
            assert snap.collection("users").get(uid) == {"v": 1}
            assert users.get(uid) == {"v": 2}

    def test_snapshot_iteration(self, db):
        users = db.collection("users")
        for i in range(3):
            users.insert({"i": i})
        with db.snapshot() as snap:
            seen = list(snap.collection("users"))
        assert sorted(d["i"] for _, d in seen) == [0, 1, 2]

    def test_snapshot_threads(self, db):
        """Snapshots are lock-free — many readers in parallel must work."""
        users = db.collection("users")
        ids = [users.insert({"i": i}) for i in range(50)]
        snap = db.snapshot()
        sc = snap.collection("users")
        errors = []

        def reader():
            try:
                for _ in range(100):
                    for did in ids:
                        d = sc.get(did)
                        assert d is not None
            except Exception as e:
                errors.append(e)

        threads = [threading.Thread(target=reader) for _ in range(8)]
        for t in threads:
            t.start()
        for t in threads:
            t.join()
        snap.close()
        assert errors == []


class TestErrors:
    def test_typed_error(self, db):
        users = db.collection("users")
        users.insert({"age": 30})
        # No index on "age" yet → NoSuchIndex.
        with pytest.raises(pyx.PyxError) as exc:
            users.find_one("age", 30)
        assert exc.value.status == -10  # PYX_NO_SUCH_INDEX
