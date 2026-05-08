# Django + pyx — realistic example

A small Django app using **pyx** (this repo's embedded document DB) as
its primary store — no relational DB, no ORM. The point is to show
what the integration actually looks like when you use pyx instead of
Postgres/SQLite for a document-shaped workload.

The app: a personal notes service. CRUD over a `notes` collection,
tag filtering via an indexed query, optimistic-concurrency for safe
concurrent edits, and a snapshot-backed list view that doesn't block
on writers.

## Important: single-process only

pyx is **not yet multi-process safe** — opening the same DB file from
multiple gunicorn / uvicorn worker processes will corrupt it (see the
project README for the full story). This example is configured to
run as a single Django process with multiple threads, which scales
fine for small-to-medium apps:

```sh
# dev
python manage.py runserver

# prod-ish (still one process, many threads):
gunicorn --workers 1 --threads 8 notes_project.wsgi:application
```

If you need multi-process scaling, this example won't fit your
deployment without phase 1C of the multi-process work landing first
(or a sidecar architecture that's outside this example's scope).

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
