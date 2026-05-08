# Django + pyx — realistic example

A small Django app using **pyx** (this repo's embedded document DB) as
its primary store — no relational DB, no ORM. The point is to show
what the integration actually looks like when you use pyx instead of
Postgres/SQLite for a document-shaped workload.

The app: a personal notes service. CRUD over a `notes` collection,
tag filtering via an indexed query, optimistic-concurrency for safe
concurrent edits, and a snapshot-backed list view that doesn't block
on writers.

## Multi-process: now actually safe

As of the phase 2 multi-process work, opening the same pyx DB from
multiple worker processes is safe — writes commit through a
cross-process WRITER lock, page allocations go through shm-resident
atomics, and the B+Tree root is in shm so every process sees every
other's commits. Verified empirically with 8 processes × 100 inserts
× 3 trials → all 800 docs preserved every time.

Practical Django deployments:

```sh
# dev
python manage.py runserver

# prod, multi-worker:
gunicorn --workers 4 notes_project.wsgi:application
```

The single-writer model still applies — only one process is in the
commit critical section at a time, so write throughput is bounded by
that. Reads are lock-free and scale across processes; the typical
web-app workload is fine.

## Why pyx here?

- **Notes are documents.** Each note has a title, body, list of tags,
  arbitrary user-defined fields. A relational schema would force a
  fixed shape; pyx stores whatever you give it.
- **Lock-free reads.** The list view uses `db.snapshot()` so the
  index page never blocks on a concurrent writer.
- **OCC for editing.** When two browser tabs edit the same note,
  `db.run_optimistic` retries on conflict instead of last-writer-wins.
- **Compound indexes** for `(user_id, tag)` queries — see
  `notes/views.py`.

## Layout

```
django/
├── README.md                    (this file)
├── requirements.txt
├── manage.py
├── notes_project/               Django project
│   ├── __init__.py
│   ├── settings.py
│   ├── urls.py
│   ├── wsgi.py
│   └── asgi.py
└── notes/                       Django app
    ├── __init__.py
    ├── apps.py
    ├── pyx_store.py             single shared Db handle (one per process)
    ├── views.py                 the actual pyx integration
    ├── urls.py
    └── templates/notes/
        ├── base.html
        ├── list.html
        ├── detail.html
        └── edit.html
```

## Run

```sh
# from this directory
pip install -r requirements.txt

# build the pyx native lib first (from repo root)
( cd ../.. && zig build -Doptimize=ReleaseSmall )

# Django finds libpyx via PYX_LIBRARY (or auto-discovery from the
# repo's zig-out/lib).
export PYX_LIBRARY="$PWD/../../zig-out/lib/libpyx.dylib"   # macOS
# export PYX_LIBRARY="$PWD/../../zig-out/lib/libpyx.so"    # Linux

python manage.py runserver
# → http://127.0.0.1:8000/
```

The DB file lives at `notes.pyx` in this directory; delete it to start
fresh.

## What's missing (deliberately)

- **Auth.** This is a single-tenant demo. Notes are scoped by a stub
  `user_id` query param. Wire in `django.contrib.auth` if you want
  real users; the pyx queries don't change.
- **Forms / CSRF.** Vanilla `request.POST.get()` parsing. Add
  `django.forms` and `{% csrf_token %}` for production.
- **Admin.** No SQL → no `django-admin` autogen. Build your own
  management views if you need them.
- **Migrations.** No SQL → no migrations. Schema lives in your code,
  not in a migration history.
