/* pyx native document decoder (phase 5B).
 *
 * Mirrors `bindings/python/pyx/_doc.py` byte-for-byte, but uses the
 * Python C API to construct dicts/lists/scalars directly. The pure-
 * Python `_doc.decode` stays as a fallback when this extension can't
 * be compiled or imported.
 *
 * Wire format (see _doc.py for the canonical reference):
 *
 *   value := type:u8 | payload
 *
 *   tags:
 *     0x00 null
 *     0x01 false
 *     0x02 true
 *     0x03 i64    (8 bytes LE)
 *     0x04 f64    (8 bytes IEEE LE)
 *     0x05 string (varint length + UTF-8)
 *     0x06 bytes  (varint length + raw)
 *     0x07 array  (u32 length + sequence of values)
 *     0x08 object (u32 length + sequence of entries)
 *
 *   object entry:  type:u8 | varint key_len | key bytes | payload
 *   array element: type:u8 | payload
 *
 * A pyx document is always a top-level object (tag 0x08).
 */
#define PY_SSIZE_T_CLEAN
#include <Python.h>

#include <stdint.h>
#include <string.h>

#define TAG_NULL   0
#define TAG_FALSE  1
#define TAG_TRUE   2
#define TAG_I64    3
#define TAG_F64    4
#define TAG_STRING 5
#define TAG_BYTES  6
#define TAG_ARRAY  7
#define TAG_OBJECT 8

typedef struct {
    const uint8_t *buf;
    Py_ssize_t pos;
    Py_ssize_t end;
} Reader;

static int read_varint(Reader *r, uint64_t *out) {
    uint64_t v = 0;
    int shift = 0;
    for (;;) {
        if (r->pos >= r->end) {
            PyErr_SetString(PyExc_ValueError, "truncated varint");
            return -1;
        }
        uint8_t b = r->buf[r->pos++];
        v |= ((uint64_t)(b & 0x7F)) << shift;
        if ((b & 0x80) == 0) {
            *out = v;
            return 0;
        }
        shift += 7;
        if (shift >= 64) {
            PyErr_SetString(PyExc_ValueError, "varint too large");
            return -1;
        }
    }
}

static PyObject *read_value(Reader *r);
static PyObject *read_payload(Reader *r, uint8_t tag);

static PyObject *read_value(Reader *r) {
    if (r->pos >= r->end) {
        PyErr_SetString(PyExc_ValueError, "truncated value");
        return NULL;
    }
    uint8_t tag = r->buf[r->pos++];
    return read_payload(r, tag);
}

static PyObject *read_payload(Reader *r, uint8_t tag) {
    switch (tag) {
    case TAG_NULL:
        Py_RETURN_NONE;
    case TAG_FALSE:
        Py_RETURN_FALSE;
    case TAG_TRUE:
        Py_RETURN_TRUE;
    case TAG_I64: {
        if (r->pos + 8 > r->end) {
            PyErr_SetString(PyExc_ValueError, "truncated i64");
            return NULL;
        }
        int64_t v;
        memcpy(&v, r->buf + r->pos, 8);
        r->pos += 8;
        return PyLong_FromLongLong((long long)v);
    }
    case TAG_F64: {
        if (r->pos + 8 > r->end) {
            PyErr_SetString(PyExc_ValueError, "truncated f64");
            return NULL;
        }
        double v;
        memcpy(&v, r->buf + r->pos, 8);
        r->pos += 8;
        return PyFloat_FromDouble(v);
    }
    case TAG_STRING: {
        uint64_t n;
        if (read_varint(r, &n) < 0) return NULL;
        if (r->pos + (Py_ssize_t)n > r->end) {
            PyErr_SetString(PyExc_ValueError, "truncated string");
            return NULL;
        }
        PyObject *s = PyUnicode_DecodeUTF8(
            (const char *)(r->buf + r->pos), (Py_ssize_t)n, NULL);
        if (!s) return NULL;
        r->pos += (Py_ssize_t)n;
        return s;
    }
    case TAG_BYTES: {
        uint64_t n;
        if (read_varint(r, &n) < 0) return NULL;
        if (r->pos + (Py_ssize_t)n > r->end) {
            PyErr_SetString(PyExc_ValueError, "truncated bytes");
            return NULL;
        }
        PyObject *b = PyBytes_FromStringAndSize(
            (const char *)(r->buf + r->pos), (Py_ssize_t)n);
        if (!b) return NULL;
        r->pos += (Py_ssize_t)n;
        return b;
    }
    case TAG_ARRAY: {
        if (r->pos + 4 > r->end) {
            PyErr_SetString(PyExc_ValueError, "truncated array length");
            return NULL;
        }
        uint32_t body_len;
        memcpy(&body_len, r->buf + r->pos, 4);
        r->pos += 4;
        Py_ssize_t end = r->pos + (Py_ssize_t)body_len;
        if (end > r->end) {
            PyErr_SetString(PyExc_ValueError, "truncated array body");
            return NULL;
        }
        PyObject *list = PyList_New(0);
        if (!list) return NULL;
        while (r->pos < end) {
            PyObject *v = read_value(r);
            if (!v) {
                Py_DECREF(list);
                return NULL;
            }
            if (PyList_Append(list, v) < 0) {
                Py_DECREF(v);
                Py_DECREF(list);
                return NULL;
            }
            Py_DECREF(v);
        }
        return list;
    }
    case TAG_OBJECT: {
        if (r->pos + 4 > r->end) {
            PyErr_SetString(PyExc_ValueError, "truncated object length");
            return NULL;
        }
        uint32_t body_len;
        memcpy(&body_len, r->buf + r->pos, 4);
        r->pos += 4;
        Py_ssize_t end = r->pos + (Py_ssize_t)body_len;
        if (end > r->end) {
            PyErr_SetString(PyExc_ValueError, "truncated object body");
            return NULL;
        }
        PyObject *dict = PyDict_New();
        if (!dict) return NULL;
        while (r->pos < end) {
            if (r->pos >= end) {
                PyErr_SetString(PyExc_ValueError, "truncated object entry");
                Py_DECREF(dict);
                return NULL;
            }
            uint8_t entry_tag = r->buf[r->pos++];
            uint64_t klen;
            if (read_varint(r, &klen) < 0) {
                Py_DECREF(dict);
                return NULL;
            }
            if (r->pos + (Py_ssize_t)klen > end) {
                PyErr_SetString(PyExc_ValueError, "truncated object key");
                Py_DECREF(dict);
                return NULL;
            }
            PyObject *key = PyUnicode_DecodeUTF8(
                (const char *)(r->buf + r->pos), (Py_ssize_t)klen, NULL);
            if (!key) {
                Py_DECREF(dict);
                return NULL;
            }
            r->pos += (Py_ssize_t)klen;
            PyObject *value = read_payload(r, entry_tag);
            if (!value) {
                Py_DECREF(key);
                Py_DECREF(dict);
                return NULL;
            }
            if (PyDict_SetItem(dict, key, value) < 0) {
                Py_DECREF(key);
                Py_DECREF(value);
                Py_DECREF(dict);
                return NULL;
            }
            Py_DECREF(key);
            Py_DECREF(value);
        }
        return dict;
    }
    default:
        PyErr_Format(PyExc_ValueError, "unknown tag: %d", (int)tag);
        return NULL;
    }
}

/* decode(buf) — `buf` must support the buffer protocol (bytes, bytearray,
 * memoryview, ctypes array, …). Returns the decoded object (a dict for
 * top-level pyx documents). */
static PyObject *py_decode(PyObject *self, PyObject *arg) {
    (void)self;
    Py_buffer view;
    if (PyObject_GetBuffer(arg, &view, PyBUF_SIMPLE) < 0) {
        return NULL;
    }
    if (view.len < 1) {
        PyBuffer_Release(&view);
        PyErr_SetString(PyExc_ValueError, "truncated document");
        return NULL;
    }
    Reader r = { .buf = (const uint8_t *)view.buf, .pos = 0, .end = view.len };
    PyObject *result = read_value(&r);
    PyBuffer_Release(&view);
    return result;
}

/* decode_many(out_buf, out_lens, ids) -> dict[int, dict].
 *
 * `out_buf`   : buffer-protocol object holding values packed in input order.
 * `out_lens`  : ctypes array (or any int-sequence) of u32 lengths per slot.
 * `ids`       : list/sequence of integer doc ids matching `out_lens`.
 *
 * Walks `out_buf` once, decoding each value of length `out_lens[i]` and
 * stuffing it into the result dict under key `ids[i]`. Skips slots
 * where `out_lens[i] == 0` (misses).
 */
static PyObject *py_decode_many(PyObject *self, PyObject *args) {
    (void)self;
    PyObject *buf_obj;
    PyObject *lens_obj;
    PyObject *ids_obj;
    if (!PyArg_ParseTuple(args, "OOO", &buf_obj, &lens_obj, &ids_obj)) {
        return NULL;
    }

    Py_buffer view;
    if (PyObject_GetBuffer(buf_obj, &view, PyBUF_SIMPLE) < 0) {
        return NULL;
    }

    Py_buffer lens_view;
    int have_lens_view = 0;
    if (PyObject_GetBuffer(lens_obj, &lens_view, PyBUF_SIMPLE) == 0) {
        /* ctypes (c_uint32 * n) exposes the buffer protocol — iterate
         * 4 bytes at a time. */
        have_lens_view = 1;
    } else {
        PyErr_Clear();
    }

    Py_ssize_t n_ids = PyObject_Length(ids_obj);
    if (n_ids < 0) goto fail;
    if (have_lens_view) {
        if (lens_view.len / (Py_ssize_t)sizeof(uint32_t) < n_ids) {
            PyErr_SetString(PyExc_ValueError, "out_lens shorter than ids");
            goto fail;
        }
    } else {
        Py_ssize_t n_lens = PyObject_Length(lens_obj);
        if (n_lens < 0) goto fail;
        if (n_lens != n_ids) {
            PyErr_SetString(PyExc_ValueError, "out_lens / ids length mismatch");
            goto fail;
        }
    }

    PyObject *result = PyDict_New();
    if (!result) goto fail;

    Py_ssize_t offset = 0;
    for (Py_ssize_t i = 0; i < n_ids; i++) {
        uint32_t ln;
        if (have_lens_view) {
            const uint32_t *lens_arr = (const uint32_t *)lens_view.buf;
            ln = lens_arr[i];
        } else {
            PyObject *len_obj = PySequence_GetItem(lens_obj, i);
            if (!len_obj) {
                Py_DECREF(result);
                goto fail;
            }
            long ll = PyLong_AsLong(len_obj);
            Py_DECREF(len_obj);
            if (ll < 0 && PyErr_Occurred()) {
                Py_DECREF(result);
                goto fail;
            }
            ln = (uint32_t)ll;
        }
        if (ln == 0) continue;
        if (offset + (Py_ssize_t)ln > view.len) {
            PyErr_SetString(PyExc_ValueError, "out_buf shorter than declared lens");
            Py_DECREF(result);
            goto fail;
        }
        Reader r = {
            .buf = (const uint8_t *)view.buf + offset,
            .pos = 0,
            .end = (Py_ssize_t)ln,
        };
        PyObject *value = read_value(&r);
        if (!value) {
            Py_DECREF(result);
            goto fail;
        }
        PyObject *id_obj = PySequence_GetItem(ids_obj, i);
        if (!id_obj) {
            Py_DECREF(value);
            Py_DECREF(result);
            goto fail;
        }
        if (PyDict_SetItem(result, id_obj, value) < 0) {
            Py_DECREF(id_obj);
            Py_DECREF(value);
            Py_DECREF(result);
            goto fail;
        }
        Py_DECREF(id_obj);
        Py_DECREF(value);
        offset += (Py_ssize_t)ln;
    }
    if (have_lens_view) PyBuffer_Release(&lens_view);
    PyBuffer_Release(&view);
    return result;

fail:
    if (have_lens_view) PyBuffer_Release(&lens_view);
    PyBuffer_Release(&view);
    return NULL;
}

/* ============================================================
 * Native encoder (phase 6) — mirrors `_doc.encode` byte-for-byte.
 *
 * Walks the Python value tree and emits the pyx binary format
 * directly into a growable buffer, then hands ownership to a
 * PyBytes object. ~10× faster than the pure-Python encoder on
 * the bulk-insert workload.
 * ============================================================ */

typedef struct {
    char *buf;
    Py_ssize_t len;
    Py_ssize_t cap;
} EncBuf;

static int enc_grow(EncBuf *e, Py_ssize_t need) {
    Py_ssize_t want = e->len + need;
    if (want <= e->cap) return 0;
    Py_ssize_t new_cap = e->cap == 0 ? 64 : e->cap;
    while (new_cap < want) new_cap *= 2;
    char *new_buf = PyMem_Realloc(e->buf, (size_t)new_cap);
    if (!new_buf) {
        PyErr_NoMemory();
        return -1;
    }
    e->buf = new_buf;
    e->cap = new_cap;
    return 0;
}

static int enc_byte(EncBuf *e, uint8_t b) {
    if (enc_grow(e, 1) < 0) return -1;
    e->buf[e->len++] = (char)b;
    return 0;
}

static int enc_raw(EncBuf *e, const void *src, Py_ssize_t n) {
    if (enc_grow(e, n) < 0) return -1;
    memcpy(e->buf + e->len, src, (size_t)n);
    e->len += n;
    return 0;
}

static int enc_varint(EncBuf *e, uint64_t v) {
    while (v >= 0x80) {
        if (enc_byte(e, (uint8_t)((v & 0x7F) | 0x80)) < 0) return -1;
        v >>= 7;
    }
    return enc_byte(e, (uint8_t)v);
}

static int enc_value(EncBuf *e, PyObject *value);

/* Returns the pyx tag for `value` and writes payload-without-tag.
 * For object/array entries the layout is `tag | (varint klen | key) |
 * payload-without-tag`, so the caller controls when the tag is
 * emitted. `enc_value` calls this after emitting the tag. */
static int enc_payload_for_tag(EncBuf *e, uint8_t tag, PyObject *value) {
    switch (tag) {
    case TAG_NULL:
    case TAG_FALSE:
    case TAG_TRUE:
        return 0;
    case TAG_I64: {
        long long v = PyLong_AsLongLong(value);
        if (v == -1 && PyErr_Occurred()) {
            /* Match the pure-Python encoder: report range errors as
             * ValueError, not OverflowError. */
            if (PyErr_ExceptionMatches(PyExc_OverflowError)) {
                PyErr_Clear();
                PyErr_SetString(PyExc_ValueError, "integer out of i64 range");
            }
            return -1;
        }
        return enc_raw(e, &v, 8);
    }
    case TAG_F64: {
        double v = PyFloat_AsDouble(value);
        if (v == -1.0 && PyErr_Occurred()) return -1;
        return enc_raw(e, &v, 8);
    }
    case TAG_STRING: {
        Py_ssize_t n = 0;
        const char *s = PyUnicode_AsUTF8AndSize(value, &n);
        if (!s) return -1;
        if (enc_varint(e, (uint64_t)n) < 0) return -1;
        return enc_raw(e, s, n);
    }
    case TAG_BYTES: {
        Py_buffer view;
        if (PyObject_GetBuffer(value, &view, PyBUF_SIMPLE) < 0) return -1;
        int rc = enc_varint(e, (uint64_t)view.len);
        if (rc == 0) rc = enc_raw(e, view.buf, view.len);
        PyBuffer_Release(&view);
        return rc;
    }
    case TAG_ARRAY: {
        if (enc_grow(e, 4) < 0) return -1;
        Py_ssize_t len_pos = e->len;
        e->len += 4;
        Py_ssize_t body_start = e->len;
        if (PyList_Check(value)) {
            Py_ssize_t n = PyList_GET_SIZE(value);
            for (Py_ssize_t i = 0; i < n; i++) {
                if (enc_value(e, PyList_GET_ITEM(value, i)) < 0) return -1;
            }
        } else if (PyTuple_Check(value)) {
            Py_ssize_t n = PyTuple_GET_SIZE(value);
            for (Py_ssize_t i = 0; i < n; i++) {
                if (enc_value(e, PyTuple_GET_ITEM(value, i)) < 0) return -1;
            }
        } else {
            /* Fall back to iterator protocol for arbitrary sequences. */
            PyObject *iter = PyObject_GetIter(value);
            if (!iter) return -1;
            PyObject *item;
            while ((item = PyIter_Next(iter)) != NULL) {
                int rc = enc_value(e, item);
                Py_DECREF(item);
                if (rc < 0) {
                    Py_DECREF(iter);
                    return -1;
                }
            }
            Py_DECREF(iter);
            if (PyErr_Occurred()) return -1;
        }
        uint32_t body_len = (uint32_t)(e->len - body_start);
        memcpy(e->buf + len_pos, &body_len, 4);
        return 0;
    }
    case TAG_OBJECT: {
        if (enc_grow(e, 4) < 0) return -1;
        Py_ssize_t len_pos = e->len;
        e->len += 4;
        Py_ssize_t body_start = e->len;
        Py_ssize_t pos = 0;
        PyObject *key, *val;
        while (PyDict_Next(value, &pos, &key, &val)) {
            if (!PyUnicode_Check(key)) {
                PyErr_SetString(PyExc_TypeError, "object keys must be strings");
                return -1;
            }
            uint8_t v_tag;
            if (val == Py_None) v_tag = TAG_NULL;
            else if (val == Py_True) v_tag = TAG_TRUE;
            else if (val == Py_False) v_tag = TAG_FALSE;
            else if (PyBool_Check(val)) v_tag = (val == Py_True) ? TAG_TRUE : TAG_FALSE;
            else if (PyLong_Check(val)) v_tag = TAG_I64;
            else if (PyFloat_Check(val)) v_tag = TAG_F64;
            else if (PyUnicode_Check(val)) v_tag = TAG_STRING;
            else if (PyBytes_Check(val) || PyByteArray_Check(val)) v_tag = TAG_BYTES;
            else if (PyList_Check(val) || PyTuple_Check(val)) v_tag = TAG_ARRAY;
            else if (PyDict_Check(val)) v_tag = TAG_OBJECT;
            else {
                PyErr_Format(PyExc_TypeError,
                    "unsupported value type: %s", Py_TYPE(val)->tp_name);
                return -1;
            }
            if (enc_byte(e, v_tag) < 0) return -1;
            Py_ssize_t klen = 0;
            const char *kbytes = PyUnicode_AsUTF8AndSize(key, &klen);
            if (!kbytes) return -1;
            if (enc_varint(e, (uint64_t)klen) < 0) return -1;
            if (enc_raw(e, kbytes, klen) < 0) return -1;
            if (enc_payload_for_tag(e, v_tag, val) < 0) return -1;
        }
        uint32_t body_len = (uint32_t)(e->len - body_start);
        memcpy(e->buf + len_pos, &body_len, 4);
        return 0;
    }
    default:
        PyErr_Format(PyExc_ValueError, "internal: unknown tag %d", (int)tag);
        return -1;
    }
}

/* Used by array elements: tag + payload. (Object entries handle
 * tag+key+payload manually so they can interleave the key.) */
static int enc_value(EncBuf *e, PyObject *value) {
    uint8_t tag;
    if (value == Py_None) tag = TAG_NULL;
    else if (value == Py_True) tag = TAG_TRUE;
    else if (value == Py_False) tag = TAG_FALSE;
    else if (PyBool_Check(value)) tag = (value == Py_True) ? TAG_TRUE : TAG_FALSE;
    else if (PyLong_Check(value)) tag = TAG_I64;
    else if (PyFloat_Check(value)) tag = TAG_F64;
    else if (PyUnicode_Check(value)) tag = TAG_STRING;
    else if (PyBytes_Check(value) || PyByteArray_Check(value)) tag = TAG_BYTES;
    else if (PyList_Check(value) || PyTuple_Check(value)) tag = TAG_ARRAY;
    else if (PyDict_Check(value)) tag = TAG_OBJECT;
    else {
        PyErr_Format(PyExc_TypeError,
            "unsupported value type: %s", Py_TYPE(value)->tp_name);
        return -1;
    }
    if (enc_byte(e, tag) < 0) return -1;
    return enc_payload_for_tag(e, tag, value);
}

/* encode(doc) -> bytes — pyx-encode a single dict. */
static PyObject *py_encode(PyObject *self, PyObject *arg) {
    (void)self;
    if (!PyDict_Check(arg)) {
        PyErr_SetString(PyExc_TypeError, "top-level document must be a dict");
        return NULL;
    }
    EncBuf e = {0};
    if (enc_value(&e, arg) < 0) {
        PyMem_Free(e.buf);
        return NULL;
    }
    PyObject *out = PyBytes_FromStringAndSize(e.buf, e.len);
    PyMem_Free(e.buf);
    return out;
}

/* encode_many(docs) -> (bytes, list[int]) — encode every dict in
 * `docs` into one packed bytes buffer plus a per-doc length list.
 * Used by `Collection.insert_many`: the wrapper feeds the bytes
 * straight into ctypes via from_buffer_copy without per-doc
 * round-trips. */
static PyObject *py_encode_many(PyObject *self, PyObject *arg) {
    (void)self;
    PyObject *seq = PySequence_Fast(arg, "docs must be a sequence");
    if (!seq) return NULL;

    Py_ssize_t n = PySequence_Fast_GET_SIZE(seq);
    PyObject **items = PySequence_Fast_ITEMS(seq);

    PyObject *lens = PyList_New(n);
    if (!lens) {
        Py_DECREF(seq);
        return NULL;
    }

    EncBuf e = {0};
    for (Py_ssize_t i = 0; i < n; i++) {
        PyObject *d = items[i];
        if (!PyDict_Check(d)) {
            PyErr_SetString(PyExc_TypeError, "every doc must be a dict");
            goto fail;
        }
        Py_ssize_t before = e.len;
        if (enc_value(&e, d) < 0) goto fail;
        Py_ssize_t doc_len = e.len - before;
        PyObject *ln_obj = PyLong_FromSsize_t(doc_len);
        if (!ln_obj) goto fail;
        PyList_SET_ITEM(lens, i, ln_obj); /* steals ref */
    }

    PyObject *packed = PyBytes_FromStringAndSize(e.buf, e.len);
    PyMem_Free(e.buf);
    Py_DECREF(seq);
    if (!packed) {
        Py_DECREF(lens);
        return NULL;
    }
    PyObject *result = PyTuple_Pack(2, packed, lens);
    Py_DECREF(packed);
    Py_DECREF(lens);
    return result;

fail:
    PyMem_Free(e.buf);
    Py_DECREF(lens);
    Py_DECREF(seq);
    return NULL;
}

static PyMethodDef NativeMethods[] = {
    {"decode", py_decode, METH_O,
     "decode(buf) -> object. Decode a pyx-encoded document."},
    {"decode_many", py_decode_many, METH_VARARGS,
     "decode_many(out_buf, out_lens, ids) -> dict[int, dict]. "
     "Decode N values packed in `out_buf` according to `out_lens`, keyed by `ids`."},
    {"encode", py_encode, METH_O,
     "encode(doc) -> bytes. Encode a dict as a pyx document."},
    {"encode_many", py_encode_many, METH_O,
     "encode_many(docs) -> (bytes, list[int]). "
     "Encode N dicts into one packed buffer + a per-doc length list."},
    {NULL, NULL, 0, NULL},
};

static struct PyModuleDef nativemodule = {
    PyModuleDef_HEAD_INIT,
    "pyx._native",
    "Native document codec for pyx (phase 5B).",
    -1,
    NativeMethods,
    NULL, NULL, NULL, NULL,
};

PyMODINIT_FUNC PyInit__native(void) {
    return PyModule_Create(&nativemodule);
}
