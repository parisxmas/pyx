/*
 * pyx — embeddable document database. C ABI v0.1.0.
 *
 * Design notes
 * ============
 *
 *  - Strings (collection names, field names) are passed as (ptr, len) — NOT
 *    null-terminated. Pass UTF-8 bytes.
 *  - Documents are passed as (ptr, len) of pyx's binary doc format. Build
 *    them via your language binding's encoder, or via std.json + an encoder
 *    on the Zig side. JSON helpers may be added in a later version.
 *  - Output buffers are allocated by pyx and MUST be released with
 *    `pyx_buf_free`. Calling `pyx_buf_free` on a zero-length buffer is a
 *    no-op; the struct's `data` is set to NULL on return.
 *  - Iterators borrow into pyx-owned memory and become invalid on the next
 *    `_next`/`_close` call. Copy out before the next call if you need to
 *    retain.
 *  - `pyx_db` is thread-safe: any thread may call any non-iterator function
 *    on a shared `pyx_db *`. Mutating calls serialize on an internal mutex.
 *  - `pyx_iter` and `pyx_lookup` are NOT thread-safe; do not share a handle
 *    across threads.
 *  - `pyx_snapshot` reads are LOCK-FREE: any thread may issue read calls
 *    on a shared `pyx_snapshot *` concurrently with writers and other
 *    readers.
 *  - All functions returning `pyx_status` set a per-thread error message
 *    accessible via `pyx_last_error()` when the return is not PYX_OK.
 */

#ifndef PYX_H
#define PYX_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

/* ===================================================================== */
/*  Versioning                                                            */
/* ===================================================================== */

#define PYX_VERSION_MAJOR 0
#define PYX_VERSION_MINOR 1
#define PYX_VERSION_PATCH 0

/* Packed version: (major << 16) | (minor << 8) | patch. */
uint32_t    pyx_version(void);
const char *pyx_version_string(void);

/* On-disk format version. Files written by a different format version may
 * not be readable by this build. Bump when the page layout changes. */
uint32_t    pyx_format_version(void);

/* ===================================================================== */
/*  Status codes                                                          */
/* ===================================================================== */

typedef enum pyx_status {
    PYX_OK = 0,

    /* Non-error conditions. */
    PYX_NOT_FOUND = 1,
    PYX_END = 2,                          /* iterator exhausted */

    /* Error conditions (negative). */
    PYX_INVALID_ARG = -1,
    PYX_OUT_OF_MEMORY = -2,
    PYX_IO_ERROR = -3,
    PYX_CORRUPT_DB = -4,
    PYX_TXN_ALREADY_ACTIVE = -5,
    PYX_NO_ACTIVE_TXN = -6,
    PYX_KEY_TOO_LARGE = -7,
    PYX_VALUE_TOO_LARGE = -8,
    PYX_COLLECTION_NAME_INVALID = -9,
    PYX_NO_SUCH_INDEX = -10,
    PYX_UNSUPPORTED_FIELD_TYPE = -11,
    PYX_INTERNAL = -99,
} pyx_status;

const char *pyx_status_string(pyx_status status);

/* Returns the last error message produced on the calling thread, or
 * "no error" if no error has been recorded since thread start. The pointer
 * is valid until the next pyx call on this thread. */
const char *pyx_last_error(void);

/* ===================================================================== */
/*  Opaque types                                                          */
/* ===================================================================== */

typedef struct pyx_db        pyx_db;
typedef struct pyx_snapshot  pyx_snapshot;
typedef struct pyx_iter      pyx_iter;
typedef struct pyx_lookup    pyx_lookup;

/* Owned-byte output. pyx allocates `data`; caller releases via pyx_buf_free.
 * `data` is NULL when `len == 0`. */
typedef struct pyx_buf {
    uint8_t *data;
    size_t   len;
} pyx_buf;

void pyx_buf_free(pyx_buf *buf);

/* ===================================================================== */
/*  Tagged values (used by indexed lookups)                               */
/* ===================================================================== */

typedef enum pyx_value_type {
    PYX_VAL_NULL = 0,
    PYX_VAL_BOOL = 1,
    PYX_VAL_I64  = 2,
    PYX_VAL_F64  = 3,
    PYX_VAL_STRING = 4,
} pyx_value_type;

typedef struct pyx_value {
    pyx_value_type type;
    union {
        int64_t  i64;
        double   f64;
        uint8_t  boolean; /* 0 or 1 */
        struct { const char *ptr; size_t len; } string;
    } as;
} pyx_value;

typedef enum pyx_bound_kind {
    PYX_BOUND_NONE = 0,
    PYX_BOUND_INCLUSIVE = 1,
    PYX_BOUND_EXCLUSIVE = 2,
} pyx_bound_kind;

typedef struct pyx_bound {
    pyx_bound_kind kind;
    pyx_value      value; /* ignored when kind == PYX_BOUND_NONE */
} pyx_bound;

/* ===================================================================== */
/*  Database lifecycle                                                    */
/* ===================================================================== */

typedef enum pyx_sync_mode {
    PYX_SYNC_FULL   = 0, /* fsync the WAL on every commit (strongest) */
    PYX_SYNC_NORMAL = 1, /* fsync only at checkpoint (faster) */
} pyx_sync_mode;

/* Open a database file (creates if missing). On success returns PYX_OK and
 * stores a pointer to the new db in *out_db. The caller must release the
 * db with pyx_close.
 *
 *  path:    UTF-8 path on the local filesystem (null-terminated).
 *  out_db:  receives the opened db handle.
 *
 * Thread safety: must not be called concurrently with itself for the same
 * path. The returned handle is thread-safe for subsequent operations. */
pyx_status pyx_open(const char *path, pyx_db **out_db);

/* Close a database. After this call, all derived handles (snapshots,
 * iterators) become invalid and must not be used. Idempotent if `db` is
 * NULL. Performs a best-effort checkpoint to flush the page cache. */
void pyx_close(pyx_db *db);

/* Configure durability. PYX_SYNC_NORMAL skips fsync on each commit; the
 * page cache + WAL fsync only happen at pyx_checkpoint or pyx_close. The
 * data file is never corrupted; only the most recent commits may be lost
 * on power loss (the same trade-off as SQLite's WAL+synchronous=NORMAL). */
void pyx_set_sync_mode(pyx_db *db, pyx_sync_mode mode);

/* Flush the page cache and WAL to disk. Optional — pyx_close also does it. */
pyx_status pyx_checkpoint(pyx_db *db);

/* ===================================================================== */
/*  Transactions                                                          */
/* ===================================================================== */

/* Open an explicit multi-op transaction. While held, all mutating ops on
 * this db's collections from THIS THREAD join the transaction. Other
 * threads' calls block on the transaction's mutex until commit/abort.
 *
 * It is an error to call pyx_begin while this thread already owns a txn. */
pyx_status pyx_begin(pyx_db *db);

/* Commit the explicit transaction. Releases the lock. */
pyx_status pyx_commit(pyx_db *db);

/* Abort the explicit transaction. Releases the lock. */
void       pyx_abort(pyx_db *db);

/* ===================================================================== */
/*  Document operations (binary doc format)                               */
/* ===================================================================== */

/* Insert a new document. Allocates a new monotonic doc id and stores it.
 *  out_doc_id: receives the assigned id on success. Must not be NULL. */
pyx_status pyx_insert(
    pyx_db *db,
    const char *coll, size_t coll_len,
    const uint8_t *doc, size_t doc_len,
    uint64_t *out_doc_id);

/* Insert or replace a document at a specific id. */
pyx_status pyx_put(
    pyx_db *db,
    const char *coll, size_t coll_len,
    uint64_t doc_id,
    const uint8_t *doc, size_t doc_len);

/* Read a document by id. Returns:
 *  - PYX_OK if found; *out fills with pyx-owned bytes (caller frees with
 *    pyx_buf_free).
 *  - PYX_NOT_FOUND if no document with that id; *out is zeroed.
 *  - any error otherwise. */
pyx_status pyx_get(
    pyx_db *db,
    const char *coll, size_t coll_len,
    uint64_t doc_id,
    pyx_buf *out);

/* Delete a document by id. Returns:
 *  - PYX_OK if a document was deleted.
 *  - PYX_NOT_FOUND if no document with that id existed. */
pyx_status pyx_delete(
    pyx_db *db,
    const char *coll, size_t coll_len,
    uint64_t doc_id);

/* ===================================================================== */
/*  Iteration                                                             */
/* ===================================================================== */

/* Open a forward iterator over a collection. Yields documents in
 * ascending doc-id order. Iterators are NOT thread-safe; one thread per
 * iterator. */
pyx_status pyx_iter_open(
    pyx_db *db,
    const char *coll, size_t coll_len,
    pyx_iter **out_iter);

/* Advance the iterator. On PYX_OK fills *out_doc_id and *out_doc;
 * the bytes pointed to by out_doc->data are valid until the next call to
 * pyx_iter_next/pyx_iter_close on this iterator. Do NOT call pyx_buf_free
 * on the borrowed buffer.
 *
 * Returns PYX_END when the iterator is exhausted. */
pyx_status pyx_iter_next(
    pyx_iter *iter,
    uint64_t *out_doc_id,
    pyx_buf  *out_doc); /* borrowed; do NOT free */

void pyx_iter_close(pyx_iter *iter);

/* ===================================================================== */
/*  Indexes (string + i64 only in v0)                                     */
/* ===================================================================== */

pyx_status pyx_create_index(
    pyx_db *db,
    const char *coll, size_t coll_len,
    const char *field, size_t field_len);

pyx_status pyx_drop_index(
    pyx_db *db,
    const char *coll, size_t coll_len,
    const char *field, size_t field_len);

/* Equality lookup. Returns PYX_OK with *out_doc_id set, or PYX_NOT_FOUND. */
pyx_status pyx_find_one(
    pyx_db *db,
    const char *coll, size_t coll_len,
    const char *field, size_t field_len,
    const pyx_value *value,
    uint64_t *out_doc_id);

/* Range lookup. Either lo or hi (or both) may be NULL or PYX_BOUND_NONE
 * to indicate unbounded. Caller releases with pyx_lookup_close. */
pyx_status pyx_find_range(
    pyx_db *db,
    const char *coll, size_t coll_len,
    const char *field, size_t field_len,
    const pyx_bound *lo,
    const pyx_bound *hi,
    pyx_lookup **out_lookup);

/* Advance a lookup. Returns PYX_OK with *out_doc_id, PYX_END at exhaustion. */
pyx_status pyx_lookup_next(pyx_lookup *l, uint64_t *out_doc_id);
void       pyx_lookup_close(pyx_lookup *l);

/* ===================================================================== */
/*  Snapshots — lock-free reads from any thread                           */
/* ===================================================================== */

/* Capture a consistent point-in-time view of the database. Internally
 * checkpoints (so all reachable pages are durable on disk) and stores
 * the captured root. Subsequent reads through the snapshot bypass the
 * mutex entirely — N reader threads read in parallel.
 *
 * The snapshot does NOT see writes that occur after pyx_snapshot_open
 * returns. */
pyx_status pyx_snapshot_open(pyx_db *db, pyx_snapshot **out_snap);

/* Release the snapshot. Idempotent on NULL. */
void       pyx_snapshot_close(pyx_snapshot *snap);

pyx_status pyx_snapshot_get(
    pyx_snapshot *snap,
    const char *coll, size_t coll_len,
    uint64_t doc_id,
    pyx_buf *out);

pyx_status pyx_snapshot_iter_open(
    pyx_snapshot *snap,
    const char *coll, size_t coll_len,
    pyx_iter **out_iter);

pyx_status pyx_snapshot_find_one(
    pyx_snapshot *snap,
    const char *coll, size_t coll_len,
    const char *field, size_t field_len,
    const pyx_value *value,
    uint64_t *out_doc_id);

pyx_status pyx_snapshot_find_range(
    pyx_snapshot *snap,
    const char *coll, size_t coll_len,
    const char *field, size_t field_len,
    const pyx_bound *lo,
    const pyx_bound *hi,
    pyx_lookup **out_lookup);

#ifdef __cplusplus
} /* extern "C" */
#endif

#endif /* PYX_H */
