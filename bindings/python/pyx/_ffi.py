"""ctypes bindings to libpyx — keep in lockstep with include/pyx.h.

Loads `libpyx.dylib` / `libpyx.so` / `pyx.dll` from a few well-known
locations so the package works both during development (loads the build
artifact under zig-out/) and after install (loads from the installed
prefix).
"""
from __future__ import annotations

import ctypes as C
import os
import sys
from pathlib import Path

# -------------------------------------------------------------------
# Library loading
# -------------------------------------------------------------------

def _candidate_paths() -> list[Path]:
    """Search order: explicit env var, package-bundled lib, zig-out, system."""
    paths: list[Path] = []
    if env := os.environ.get("PYX_LIBRARY"):
        paths.append(Path(env))

    pkg_dir = Path(__file__).resolve().parent
    # Package-bundled (post-install).
    for name in ("libpyx.dylib", "libpyx.so", "pyx.dll"):
        paths.append(pkg_dir / name)
    # Development checkout: bindings/python/pyx -> ../../../zig-out/lib
    repo_lib = pkg_dir.parent.parent.parent / "zig-out" / "lib"
    for name in ("libpyx.dylib", "libpyx.so", "pyx.dll"):
        paths.append(repo_lib / name)
    return paths


def _load_library() -> C.CDLL:
    last_err = None
    for p in _candidate_paths():
        if p.exists():
            try:
                return C.CDLL(str(p))
            except OSError as e:
                last_err = e
                continue
    msg = (
        "could not locate libpyx. Set the PYX_LIBRARY env var to its path,\n"
        "or run `zig build -Doptimize=ReleaseSmall` in the project root."
    )
    if last_err:
        msg += f"\nLast load error: {last_err}"
    raise RuntimeError(msg)


_lib = _load_library()


# -------------------------------------------------------------------
# C ABI types — mirror include/pyx.h
# -------------------------------------------------------------------

class PyxBuf(C.Structure):
    _fields_ = [
        ("data", C.POINTER(C.c_uint8)),
        ("len", C.c_size_t),
    ]


class _ValStr(C.Structure):
    _fields_ = [("ptr", C.POINTER(C.c_uint8)), ("len", C.c_size_t)]


class _ValAs(C.Union):
    _fields_ = [
        ("i64_v", C.c_int64),
        ("f64_v", C.c_double),
        ("boolean", C.c_uint8),
        ("string", _ValStr),
    ]


class PyxValue(C.Structure):
    # Note: the C struct field is named `as` but `as` is a Python reserved
    # word, so ctypes exposes it as `as_` here.
    _fields_ = [("type", C.c_int), ("as_", _ValAs)]


class PyxBound(C.Structure):
    _fields_ = [("kind", C.c_int), ("value", PyxValue)]


# Status codes — match the C enum exactly.
PYX_OK = 0
PYX_NOT_FOUND = 1
PYX_END = 2
PYX_INVALID_ARG = -1
PYX_OUT_OF_MEMORY = -2
PYX_IO_ERROR = -3
PYX_CORRUPT_DB = -4
PYX_TXN_ALREADY_ACTIVE = -5
PYX_NO_ACTIVE_TXN = -6
PYX_KEY_TOO_LARGE = -7
PYX_VALUE_TOO_LARGE = -8
PYX_COLLECTION_NAME_INVALID = -9
PYX_NO_SUCH_INDEX = -10
PYX_UNSUPPORTED_FIELD_TYPE = -11
PYX_WRITE_CONFLICT = -12
PYX_RETRY_BUDGET_EXHAUSTED = -13
PYX_INTERNAL = -99

# Value type tags.
PYX_VAL_NULL = 0
PYX_VAL_BOOL = 1
PYX_VAL_I64 = 2
PYX_VAL_F64 = 3
PYX_VAL_STRING = 4

# Bound kinds.
PYX_BOUND_NONE = 0
PYX_BOUND_INCLUSIVE = 1
PYX_BOUND_EXCLUSIVE = 2

# Sync modes.
PYX_SYNC_FULL = 0
PYX_SYNC_NORMAL = 1


# -------------------------------------------------------------------
# Function signatures
# -------------------------------------------------------------------

def _bind(name: str, restype, *argtypes):
    fn = getattr(_lib, name)
    fn.restype = restype
    fn.argtypes = list(argtypes)
    return fn


# Versioning / errors
pyx_version = _bind("pyx_version", C.c_uint32)
pyx_version_string = _bind("pyx_version_string", C.c_char_p)
pyx_format_version = _bind("pyx_format_version", C.c_uint32)
pyx_status_string = _bind("pyx_status_string", C.c_char_p, C.c_int)
pyx_last_error = _bind("pyx_last_error", C.c_char_p)

# Lifecycle
pyx_open = _bind("pyx_open", C.c_int, C.c_char_p, C.POINTER(C.c_void_p))
pyx_close = _bind("pyx_close", None, C.c_void_p)
pyx_set_sync_mode = _bind("pyx_set_sync_mode", None, C.c_void_p, C.c_int)
pyx_checkpoint = _bind("pyx_checkpoint", C.c_int, C.c_void_p)

# Transactions
pyx_begin = _bind("pyx_begin", C.c_int, C.c_void_p)
pyx_commit = _bind("pyx_commit", C.c_int, C.c_void_p)
pyx_abort = _bind("pyx_abort", None, C.c_void_p)

# Buffer
pyx_buf_free = _bind("pyx_buf_free", None, C.POINTER(PyxBuf))

# Doc ops
pyx_insert = _bind(
    "pyx_insert",
    C.c_int,
    C.c_void_p, C.c_char_p, C.c_size_t,
    C.POINTER(C.c_uint8), C.c_size_t,
    C.POINTER(C.c_uint64),
)
pyx_put = _bind(
    "pyx_put",
    C.c_int,
    C.c_void_p, C.c_char_p, C.c_size_t,
    C.c_uint64,
    C.POINTER(C.c_uint8), C.c_size_t,
)
pyx_get = _bind(
    "pyx_get",
    C.c_int,
    C.c_void_p, C.c_char_p, C.c_size_t, C.c_uint64,
    C.POINTER(PyxBuf),
)
pyx_delete = _bind(
    "pyx_delete",
    C.c_int,
    C.c_void_p, C.c_char_p, C.c_size_t, C.c_uint64,
)

# Iteration
pyx_iter_open = _bind(
    "pyx_iter_open",
    C.c_int,
    C.c_void_p, C.c_char_p, C.c_size_t,
    C.POINTER(C.c_void_p),
)
pyx_iter_next = _bind(
    "pyx_iter_next",
    C.c_int,
    C.c_void_p, C.POINTER(C.c_uint64), C.POINTER(PyxBuf),
)
pyx_iter_close = _bind("pyx_iter_close", None, C.c_void_p)

# Indexes
pyx_create_index = _bind(
    "pyx_create_index",
    C.c_int,
    C.c_void_p, C.c_char_p, C.c_size_t, C.c_char_p, C.c_size_t,
)
pyx_drop_index = _bind(
    "pyx_drop_index",
    C.c_int,
    C.c_void_p, C.c_char_p, C.c_size_t, C.c_char_p, C.c_size_t,
)
pyx_find_one = _bind(
    "pyx_find_one",
    C.c_int,
    C.c_void_p, C.c_char_p, C.c_size_t, C.c_char_p, C.c_size_t,
    C.POINTER(PyxValue), C.POINTER(C.c_uint64),
)
pyx_find_range = _bind(
    "pyx_find_range",
    C.c_int,
    C.c_void_p, C.c_char_p, C.c_size_t, C.c_char_p, C.c_size_t,
    C.POINTER(PyxBound), C.POINTER(PyxBound),
    C.POINTER(C.c_void_p),
)
pyx_lookup_next = _bind("pyx_lookup_next", C.c_int, C.c_void_p, C.POINTER(C.c_uint64))
pyx_lookup_close = _bind("pyx_lookup_close", None, C.c_void_p)

# Snapshots
pyx_snapshot_open = _bind("pyx_snapshot_open", C.c_int, C.c_void_p, C.POINTER(C.c_void_p))
pyx_snapshot_close = _bind("pyx_snapshot_close", None, C.c_void_p)
pyx_snapshot_get = _bind(
    "pyx_snapshot_get",
    C.c_int,
    C.c_void_p, C.c_char_p, C.c_size_t, C.c_uint64,
    C.POINTER(PyxBuf),
)
pyx_snapshot_iter_open = _bind(
    "pyx_snapshot_iter_open",
    C.c_int,
    C.c_void_p, C.c_char_p, C.c_size_t,
    C.POINTER(C.c_void_p),
)
pyx_snapshot_find_one = _bind(
    "pyx_snapshot_find_one",
    C.c_int,
    C.c_void_p, C.c_char_p, C.c_size_t, C.c_char_p, C.c_size_t,
    C.POINTER(PyxValue), C.POINTER(C.c_uint64),
)
pyx_snapshot_find_range = _bind(
    "pyx_snapshot_find_range",
    C.c_int,
    C.c_void_p, C.c_char_p, C.c_size_t, C.c_char_p, C.c_size_t,
    C.POINTER(PyxBound), C.POINTER(PyxBound),
    C.POINTER(C.c_void_p),
)

# Optimistic concurrency
pyx_begin_optimistic = _bind(
    "pyx_begin_optimistic", C.c_int, C.c_void_p, C.POINTER(C.c_void_p)
)
pyx_optimistic_commit = _bind("pyx_optimistic_commit", C.c_int, C.c_void_p)
pyx_optimistic_abort = _bind("pyx_optimistic_abort", None, C.c_void_p)
pyx_optimistic_insert = _bind(
    "pyx_optimistic_insert",
    C.c_int,
    C.c_void_p, C.c_char_p, C.c_size_t,
    C.POINTER(C.c_uint8), C.c_size_t,
    C.POINTER(C.c_uint64),
)
pyx_optimistic_put = _bind(
    "pyx_optimistic_put",
    C.c_int,
    C.c_void_p, C.c_char_p, C.c_size_t,
    C.c_uint64,
    C.POINTER(C.c_uint8), C.c_size_t,
)
pyx_optimistic_delete = _bind(
    "pyx_optimistic_delete",
    C.c_int,
    C.c_void_p, C.c_char_p, C.c_size_t, C.c_uint64,
)
pyx_optimistic_get = _bind(
    "pyx_optimistic_get",
    C.c_int,
    C.c_void_p, C.c_char_p, C.c_size_t, C.c_uint64,
    C.POINTER(PyxBuf),
)
pyx_optimistic_find_one = _bind(
    "pyx_optimistic_find_one",
    C.c_int,
    C.c_void_p, C.c_char_p, C.c_size_t, C.c_char_p, C.c_size_t,
    C.POINTER(PyxValue), C.POINTER(C.c_uint64),
)
