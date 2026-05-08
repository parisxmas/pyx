"""pyx vs SQLite — side-by-side Python benchmark.

Workloads:
  W1 — Single-process sequential inserts (autocommit-style)
  W2 — Single-process random reads from a pre-populated DB
  W3 — Multi-process inserts to N **separate** tables/collections
       (this is the workload pyx 0.5.0's per-collection writer
        locks are designed for)
  W4 — Multi-process inserts to a SHARED table/collection
       (single-writer ceiling; both DBs serialize)

Both DBs run in a comparable durability mode:
  - SQLite: WAL journal mode + synchronous=FULL
  - pyx:    .full sync mode (the default)

The benchmark prints a side-by-side table at the end. Numbers are
single-shot wall clock — re-run a few times for noise; the goal is
order-of-magnitude comparison and showing where each DB shines.

Run:
    PYX_LIBRARY=/path/to/libpyx.dylib python bench_pyx_vs_sqlite.py
"""
from __future__ import annotations

import argparse
import multiprocessing as mp
import os
import sqlite3
import sys
import tempfile
import time
from dataclasses import dataclass
from pathlib import Path

import pyx


# ============================================================
# Helpers
# ============================================================

@dataclass
class Result:
    name: str
    pyx_s: float
    sqlite_s: float
    pyx_ops: int
    sqlite_ops: int

    @property
    def pyx_throughput(self) -> float:
        return self.pyx_ops / self.pyx_s if self.pyx_s > 0 else 0.0

    @property
    def sqlite_throughput(self) -> float:
        return self.sqlite_ops / self.sqlite_s if self.sqlite_s > 0 else 0.0


def cleanup(path: str) -> None:
    for suffix in ("", ".wal", "-shm", "-journal"):
        p = path + suffix
        try:
            os.unlink(p)
        except FileNotFoundError:
            pass


def open_sqlite(path: str) -> sqlite3.Connection:
    """Open SQLite with WAL + synchronous=FULL for fairness vs pyx's
    default `.full` durability."""
    conn = sqlite3.connect(path, isolation_level=None)  # autocommit on
    conn.execute("PRAGMA journal_mode=WAL")
    conn.execute("PRAGMA synchronous=FULL")
    return conn


# ============================================================
# W1 — Single-process sequential inserts
# ============================================================

def w1_pyx(path: str, n: int) -> float:
    cleanup(path)
    db = pyx.Db.open(path)
    c = db.collection("notes")
    t0 = time.perf_counter()
    for i in range(n):
        c.insert({"i": i, "title": f"note-{i}", "body": "lorem ipsum"})
    elapsed = time.perf_counter() - t0
    db.close()
    cleanup(path)
    return elapsed


def w1_sqlite(path: str, n: int) -> float:
    cleanup(path)
    conn = open_sqlite(path)
    conn.execute(
        "CREATE TABLE notes (id INTEGER PRIMARY KEY, i INTEGER, title TEXT, body TEXT)"
    )
    t0 = time.perf_counter()
    for i in range(n):
        conn.execute(
            "INSERT INTO notes (i, title, body) VALUES (?, ?, ?)",
            (i, f"note-{i}", "lorem ipsum"),
        )
    elapsed = time.perf_counter() - t0
    conn.close()
    cleanup(path)
    return elapsed


# ============================================================
# W2 — Random reads from a pre-populated DB
# ============================================================

def w2_pyx(path: str, n_seed: int, n_reads: int) -> float:
    cleanup(path)
    db = pyx.Db.open(path)
    c = db.collection("notes")
    ids = [c.insert({"i": i, "title": f"note-{i}"}) for i in range(n_seed)]
    import random
    rng = random.Random(42)
    targets = [rng.choice(ids) for _ in range(n_reads)]

    t0 = time.perf_counter()
    for did in targets:
        c.get(did)
    elapsed = time.perf_counter() - t0

    db.close()
    cleanup(path)
    return elapsed


def w2_sqlite(path: str, n_seed: int, n_reads: int) -> float:
    cleanup(path)
    conn = open_sqlite(path)
    conn.execute(
        "CREATE TABLE notes (id INTEGER PRIMARY KEY, i INTEGER, title TEXT)"
    )
    for i in range(n_seed):
        conn.execute("INSERT INTO notes (i, title) VALUES (?, ?)", (i, f"note-{i}"))

    import random
    rng = random.Random(42)
    targets = [rng.randint(1, n_seed) for _ in range(n_reads)]

    t0 = time.perf_counter()
    cur = conn.cursor()
    for did in targets:
        cur.execute("SELECT i, title FROM notes WHERE id = ?", (did,)).fetchone()
    elapsed = time.perf_counter() - t0

    conn.close()
    cleanup(path)
    return elapsed


# ============================================================
# W3 — Multi-process inserts to SEPARATE tables/collections
# ============================================================

# Workers must be top-level for spawn to pickle them.

def _w3_pyx_worker(args: tuple[str, str, int]) -> None:
    path, name, n = args
    db = pyx.Db.open(path)
    c = db.collection(name)
    for i in range(n):
        c.insert({"i": i, "from": name})
    db.close()


def _w3_sqlite_worker(args: tuple[str, str, int]) -> None:
    path, table, n = args
    conn = open_sqlite(path)
    cur = conn.cursor()
    for i in range(n):
        cur.execute(f"INSERT INTO {table} (i, name) VALUES (?, ?)", (i, table))
    conn.close()


def w3_pyx(path: str, n_procs: int, n_per: int) -> float:
    cleanup(path)
    db = pyx.Db.open(path)
    names = [f"c{k}" for k in range(n_procs)]
    for n in names:
        db.create_collection(n)
    db.close()

    args = [(path, names[k], n_per) for k in range(n_procs)]
    t0 = time.perf_counter()
    with mp.Pool(processes=n_procs) as pool:
        pool.map(_w3_pyx_worker, args)
    elapsed = time.perf_counter() - t0

    cleanup(path)
    return elapsed


def w3_sqlite(path: str, n_procs: int, n_per: int) -> float:
    cleanup(path)
    conn = open_sqlite(path)
    for k in range(n_procs):
        conn.execute(
            f"CREATE TABLE c{k} (id INTEGER PRIMARY KEY, i INTEGER, name TEXT)"
        )
    conn.close()

    args = [(path, f"c{k}", n_per) for k in range(n_procs)]
    t0 = time.perf_counter()
    with mp.Pool(processes=n_procs) as pool:
        pool.map(_w3_sqlite_worker, args)
    elapsed = time.perf_counter() - t0

    cleanup(path)
    return elapsed


# ============================================================
# W4 — Multi-process inserts to a SHARED table/collection
# ============================================================

def _w4_pyx_worker(args: tuple[str, int]) -> None:
    path, n = args
    db = pyx.Db.open(path)
    c = db.collection("shared")
    for i in range(n):
        c.insert({"i": i})
    db.close()


def _w4_sqlite_worker(args: tuple[str, int]) -> None:
    path, n = args
    conn = open_sqlite(path)
    cur = conn.cursor()
    for i in range(n):
        # SQLite's busy_timeout helps under contention.
        cur.execute("INSERT INTO shared (i) VALUES (?)", (i,))
    conn.close()


def w4_pyx(path: str, n_procs: int, n_per: int) -> float:
    cleanup(path)
    db = pyx.Db.open(path)
    db.close()

    args = [(path, n_per)] * n_procs
    t0 = time.perf_counter()
    with mp.Pool(processes=n_procs) as pool:
        pool.map(_w4_pyx_worker, args)
    elapsed = time.perf_counter() - t0

    cleanup(path)
    return elapsed


def w4_sqlite(path: str, n_procs: int, n_per: int) -> float:
    cleanup(path)
    conn = open_sqlite(path)
    conn.execute("CREATE TABLE shared (id INTEGER PRIMARY KEY, i INTEGER)")
    conn.execute("PRAGMA busy_timeout=30000")
    conn.close()

    args = [(path, n_per)] * n_procs
    t0 = time.perf_counter()
    with mp.Pool(processes=n_procs) as pool:
        pool.map(_w4_sqlite_worker, args)
    elapsed = time.perf_counter() - t0

    cleanup(path)
    return elapsed


# ============================================================
# Reporter
# ============================================================

def fmt_seconds(s: float) -> str:
    ms = s * 1000.0
    if ms < 1: return f"{ms*1000:.1f} µs"
    if ms < 1000: return f"{ms:.1f} ms"
    return f"{ms/1000:.2f} s"


def fmt_throughput(ops_per_s: float) -> str:
    if ops_per_s >= 1_000_000: return f"{ops_per_s/1_000_000:.2f} Mops/s"
    if ops_per_s >= 1_000: return f"{ops_per_s/1000:.1f} kops/s"
    return f"{ops_per_s:.0f} ops/s"


def report(results: list[Result]) -> None:
    name_w = max(len(r.name) for r in results) + 2
    print()
    header = f"{'workload':<{name_w}} {'pyx':>14}  {'pyx tput':>13}     {'sqlite':>14}  {'sqlite tput':>13}     {'ratio (pyx/sql)':>17}"
    print(header)
    print("-" * len(header))
    for r in results:
        ratio = r.pyx_throughput / r.sqlite_throughput if r.sqlite_throughput > 0 else 0.0
        print(
            f"{r.name:<{name_w}} "
            f"{fmt_seconds(r.pyx_s):>14}  {fmt_throughput(r.pyx_throughput):>13}     "
            f"{fmt_seconds(r.sqlite_s):>14}  {fmt_throughput(r.sqlite_throughput):>13}     "
            f"{ratio:>14.2f}x"
        )
    print()


# ============================================================
# Main
# ============================================================

def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    parser.add_argument("--n-inserts", type=int, default=2000,
                        help="rows for W1 (default %(default)s)")
    parser.add_argument("--n-reads", type=int, default=10000,
                        help="reads for W2 (default %(default)s)")
    parser.add_argument("--n-procs", type=int, default=4,
                        help="processes for W3/W4 (default %(default)s)")
    parser.add_argument("--n-per", type=int, default=200,
                        help="rows per process for W3/W4 (default %(default)s)")
    parser.add_argument("--skip-w4", action="store_true",
                        help="skip the shared-table contention bench")
    args = parser.parse_args()

    print(f"pyx version:    {getattr(pyx, '__version__', 'unknown')}")
    print(f"sqlite version: {sqlite3.sqlite_version}")
    print(f"python:         {sys.version.split()[0]}")
    print(f"args:           {vars(args)}")
    print()

    with tempfile.TemporaryDirectory() as tmp:
        pyx_path = str(Path(tmp) / "bench.pyx")
        sql_path = str(Path(tmp) / "bench.db")

        results: list[Result] = []

        print(f"W1 — single-process sequential inserts (n={args.n_inserts})...")
        results.append(Result(
            name="W1 seq inserts",
            pyx_s=w1_pyx(pyx_path, args.n_inserts),
            sqlite_s=w1_sqlite(sql_path, args.n_inserts),
            pyx_ops=args.n_inserts,
            sqlite_ops=args.n_inserts,
        ))

        print(f"W2 — single-process random reads (seed={args.n_inserts}, reads={args.n_reads})...")
        results.append(Result(
            name="W2 random reads",
            pyx_s=w2_pyx(pyx_path, args.n_inserts, args.n_reads),
            sqlite_s=w2_sqlite(sql_path, args.n_inserts, args.n_reads),
            pyx_ops=args.n_reads,
            sqlite_ops=args.n_reads,
        ))

        total = args.n_procs * args.n_per
        print(f"W3 — {args.n_procs}p × {args.n_per} inserts on SEPARATE tables/collections...")
        results.append(Result(
            name=f"W3 {args.n_procs}p separate",
            pyx_s=w3_pyx(pyx_path, args.n_procs, args.n_per),
            sqlite_s=w3_sqlite(sql_path, args.n_procs, args.n_per),
            pyx_ops=total,
            sqlite_ops=total,
        ))

        if not args.skip_w4:
            print(f"W4 — {args.n_procs}p × {args.n_per} inserts on a SHARED table/collection...")
            results.append(Result(
                name=f"W4 {args.n_procs}p shared",
                pyx_s=w4_pyx(pyx_path, args.n_procs, args.n_per),
                sqlite_s=w4_sqlite(sql_path, args.n_procs, args.n_per),
                pyx_ops=total,
                sqlite_ops=total,
            ))

        report(results)
    return 0


if __name__ == "__main__":
    sys.exit(main())
