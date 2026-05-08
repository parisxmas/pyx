"""Process-wide pyx Db handle.

Django's `runserver` and gunicorn `--workers 1` use a single Python
process. This module gives every view that process's single open `Db`
— pyx is multi-thread-safe within one process but NOT multi-process
safe yet, so do not run with `--workers >1`.

Indexes are created once per process at first use (idempotent).
"""
from __future__ import annotations

import threading

import pyx
from django.conf import settings


_lock = threading.Lock()
_db: pyx.Db | None = None


def get_db() -> pyx.Db:
    """Return the process-wide pyx handle, opening + indexing on first call."""
    global _db
    if _db is not None:
        return _db
    with _lock:
        if _db is not None:
            return _db
        db = pyx.Db.open(settings.PYX_PATH)
        # Use NORMAL durability — fsyncs at checkpoint, not on every
        # commit. Same trade-off as SQLite WAL+NORMAL. Switch to FULL
        # if you really want a fsync per commit at ~30k ops/s ceiling.
        db.set_sync_mode(normal=True)

        # Indexes used by the notes app. `create_index` is idempotent.
        db.create_index("notes", "user_id")
        db.create_index("notes", "tag")
        # Compound for `(user_id, tag)` filtering — kwargs in views
        # match this field order.
        db.create_index("notes", "user_id", "tag")

        _db = db
        return _db


def close_db() -> None:
    """Best-effort close. Useful in tests to release the file handle."""
    global _db
    with _lock:
        if _db is not None:
            _db.close()
            _db = None
