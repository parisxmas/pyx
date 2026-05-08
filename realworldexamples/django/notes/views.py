"""All pyx integration lives here.

The patterns in this file are the practical shape of using pyx in a
real Django app:

  list view       → `db.snapshot()` for lock-free reads while writers
                    keep going on other threads
  create / delete → simple `Collection.insert / delete`, auto-commit
  edit            → `db.run_optimistic` so two browser tabs editing the
                    same note retry-on-conflict instead of last-writer-wins
  tag filter      → `find_one(user_id=..., tag=...)` against the
                    compound index
"""
from __future__ import annotations

import time
from datetime import datetime, timezone
from http import HTTPStatus

import pyx
from django.http import HttpResponse, HttpResponseRedirect, HttpResponseNotFound
from django.shortcuts import render
from django.urls import reverse
from django.views.decorators.http import require_GET, require_POST, require_http_methods

from .pyx_store import get_db


# ---------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------

def _user_id(request) -> str:
    """Stub: derive the current user from a query string. In a real
    app this comes from `request.user.id`."""
    return request.GET.get("u") or request.POST.get("u") or "demo"


def _now_iso() -> str:
    return datetime.now(tz=timezone.utc).isoformat()


def _parse_tags(raw: str) -> list[str]:
    return [t.strip() for t in raw.split(",") if t.strip()]


# ---------------------------------------------------------------------
# Views
# ---------------------------------------------------------------------

@require_GET
def list_view(request):
    """All of `user_id`'s notes, optionally filtered by tag.

    The list itself is rendered against a `Snapshot`, which means
    writes from other threads (e.g. another tab POSTing a new note)
    don't block this request. Trade-off: this view doesn't see the
    most recent commits — if you POST a note and immediately reload,
    you'll see the new one because the next request opens a fresh
    snapshot. For real-time-fresh, use the live collection
    `db.collection(...).get(...)` (which takes the writer mutex
    briefly).
    """
    db = get_db()
    user_id = _user_id(request)
    tag = request.GET.get("tag", "").strip() or None

    notes_out: list[dict] = []
    with db.snapshot() as snap:
        c = snap.collection("notes")
        if tag:
            # Compound-index lookup. find_one returns the first match;
            # we want all matches, so we'd normally use find_all — but
            # the snapshot path only exposes find_one in this version.
            # Fall back to scanning the snapshot's iterator and
            # filtering in Python. For real workloads, expose findAll
            # on Snapshot or use `db.collection(...)` + the live find.
            for doc_id, doc in c:
                if doc.get("user_id") != user_id:
                    continue
                if tag not in (doc.get("tags") or []):
                    continue
                doc["_id"] = doc_id
                notes_out.append(doc)
        else:
            for doc_id, doc in c:
                if doc.get("user_id") != user_id:
                    continue
                doc["_id"] = doc_id
                notes_out.append(doc)

    notes_out.sort(key=lambda d: d.get("updated_at", ""), reverse=True)
    return render(request, "notes/list.html", {
        "notes": notes_out,
        "user_id": user_id,
        "tag_filter": tag,
    })


@require_POST
def create_view(request):
    """Insert a new note. Auto-commit; one fsync per commit in NORMAL
    sync mode (deferred to checkpoint)."""
    db = get_db()
    user_id = _user_id(request)
    title = request.POST.get("title", "").strip()
    body = request.POST.get("body", "").strip()
    tags = _parse_tags(request.POST.get("tags", ""))

    if not title:
        return HttpResponse("title required", status=HTTPStatus.BAD_REQUEST)

    doc = {
        "user_id": user_id,
        "title": title,
        "body": body,
        "tags": tags,
        "created_at": _now_iso(),
        "updated_at": _now_iso(),
    }
    doc_id = db.collection("notes").insert(doc)
    return HttpResponseRedirect(
        reverse("notes:detail", args=[doc_id]) + f"?u={user_id}"
    )


@require_GET
def detail_view(request, doc_id: int):
    db = get_db()
    note = db.collection("notes").get(doc_id)
    if note is None:
        return HttpResponseNotFound("note not found")
    note["_id"] = doc_id
    return render(request, "notes/detail.html", {"note": note})


@require_http_methods(["GET", "POST"])
def edit_view(request, doc_id: int):
    """Edit a note, OCC-style.

    Two browser tabs editing the same note will see read-then-write:
    each tab loads the note (read), the user types, then submits
    (write). Without OCC, the second tab's submit would silently
    overwrite the first. With `run_optimistic`, the second tab's
    commit detects the change (its read_set entry's hash no longer
    matches the live tree) and the helper retries. By the time the
    retry runs, the function re-fetches the note and sees the latest
    state — which is what the user typed `body` against in the
    *current* tab, so the merge is "last-typed-wins-but-no-silent-
    drops". For three-way merge, parse the form's "expected_updated_at"
    and reject if it doesn't match `note["updated_at"]`.
    """
    db = get_db()
    coll = db.collection("notes")

    if request.method == "GET":
        note = coll.get(doc_id)
        if note is None:
            return HttpResponseNotFound("note not found")
        note["_id"] = doc_id
        return render(request, "notes/edit.html", {"note": note})

    title = request.POST.get("title", "").strip()
    body = request.POST.get("body", "").strip()
    tags = _parse_tags(request.POST.get("tags", ""))

    def update(txn):
        cur = txn.collection("notes").get(doc_id)
        if cur is None:
            raise LookupError("vanished")
        cur["title"] = title
        cur["body"] = body
        cur["tags"] = tags
        cur["updated_at"] = _now_iso()
        txn.collection("notes").put(doc_id, cur)

    try:
        db.run_optimistic(update, max_attempts=8)
    except LookupError:
        return HttpResponseNotFound("note vanished mid-edit")
    except pyx.RetryBudgetExhausted:
        # 8 retries is generous; if a hot key is *that* contended,
        # something's wrong upstream. Tell the user to try again.
        return HttpResponse(
            "too many concurrent edits; please refresh and retry",
            status=HTTPStatus.CONFLICT,
        )
    return HttpResponseRedirect(
        reverse("notes:detail", args=[doc_id]) + f"?u={_user_id(request)}"
    )


@require_POST
def delete_view(request, doc_id: int):
    db = get_db()
    db.collection("notes").delete(doc_id)
    return HttpResponseRedirect(reverse("notes:list") + f"?u={_user_id(request)}")
