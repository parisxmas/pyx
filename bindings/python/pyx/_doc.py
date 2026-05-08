"""Binary document codec — mirrors `src/doc.zig`.

Wire format:
    value := type:u8 | payload

    Type tags:
        0x00  null
        0x01  false
        0x02  true
        0x03  i64    (8 bytes little-endian)
        0x04  f64    (8 bytes IEEE 754 little-endian)
        0x05  string (varint length + UTF-8 bytes)
        0x06  bytes  (varint length + raw bytes)
        0x07  array  (u32 payload-length + sequence of values)
        0x08  object (u32 payload-length + sequence of entries)

    Object entry:  type:u8 | varint key_len | key bytes | value-payload
    Array element: type:u8 | value-payload

A pyx document is always a top-level object (tag 0x08).
"""
from __future__ import annotations

import struct

# Precompiled struct unpackers — `Struct(...)`.unpack_from is several
# times faster than `int.from_bytes(buf[pos:pos+8], "little")` on
# CPython because it skips the slice + the Python-level conversion.
_UNPACK_I64 = struct.Struct("<q").unpack_from
_UNPACK_F64 = struct.Struct("<d").unpack_from
_UNPACK_U32 = struct.Struct("<I").unpack_from

TAG_NULL = 0
TAG_FALSE = 1
TAG_TRUE = 2
TAG_I64 = 3
TAG_F64 = 4
TAG_STRING = 5
TAG_BYTES = 6
TAG_ARRAY = 7
TAG_OBJECT = 8


# -------- varint (LEB128 unsigned) --------

def _write_varint(buf: bytearray, n: int) -> None:
    while True:
        lo = n & 0x7F
        n >>= 7
        if n == 0:
            buf.append(lo)
            return
        buf.append(lo | 0x80)


def _read_varint(buf: bytes, pos: int) -> tuple[int, int]:
    """Returns (value, new_position)."""
    v = 0
    shift = 0
    while True:
        if pos >= len(buf):
            raise ValueError("truncated varint")
        b = buf[pos]
        pos += 1
        v |= (b & 0x7F) << shift
        if (b & 0x80) == 0:
            return v, pos
        shift += 7
        if shift >= 64:
            raise ValueError("varint too large")


# -------- encode --------

def encode(doc: dict) -> bytes:
    """Encode a Python dict into a pyx binary document."""
    if _encode_native is not None:
        return _encode_native(doc)
    if not isinstance(doc, dict):
        raise TypeError("top-level document must be a dict")
    body = _encode_object_body(doc)
    out = bytearray()
    out.append(TAG_OBJECT)
    out.extend(len(body).to_bytes(4, "little"))
    out.extend(body)
    return bytes(out)


def _encode_pure_python(doc: dict) -> bytes:
    """The pure-Python fallback. Kept callable for tests/benchmarks
    even when the native extension is loaded."""
    if not isinstance(doc, dict):
        raise TypeError("top-level document must be a dict")
    body = _encode_object_body(doc)
    out = bytearray()
    out.append(TAG_OBJECT)
    out.extend(len(body).to_bytes(4, "little"))
    out.extend(body)
    return bytes(out)


def _encode_object_body(d: dict) -> bytes:
    out = bytearray()
    for k, v in d.items():
        if not isinstance(k, str):
            raise TypeError("object keys must be strings")
        kb = k.encode("utf-8")
        _write_object_entry(out, kb, v)
    return bytes(out)


def _encode_array_body(arr: list) -> bytes:
    out = bytearray()
    for v in arr:
        _write_array_element(out, v)
    return bytes(out)


def _write_object_entry(buf: bytearray, key_bytes: bytes, value) -> None:
    tag = _value_tag(value)
    buf.append(tag)
    _write_varint(buf, len(key_bytes))
    buf.extend(key_bytes)
    _write_value_payload(buf, tag, value)


def _write_array_element(buf: bytearray, value) -> None:
    tag = _value_tag(value)
    buf.append(tag)
    _write_value_payload(buf, tag, value)


def _value_tag(v) -> int:
    if v is None:
        return TAG_NULL
    if v is False:
        return TAG_FALSE
    if v is True:
        return TAG_TRUE
    if isinstance(v, bool):  # bool is a subclass of int — caught above
        return TAG_TRUE if v else TAG_FALSE
    if isinstance(v, int):
        return TAG_I64
    if isinstance(v, float):
        return TAG_F64
    if isinstance(v, str):
        return TAG_STRING
    if isinstance(v, (bytes, bytearray, memoryview)):
        return TAG_BYTES
    if isinstance(v, list) or isinstance(v, tuple):
        return TAG_ARRAY
    if isinstance(v, dict):
        return TAG_OBJECT
    raise TypeError(f"unsupported value type: {type(v).__name__}")


def _write_value_payload(buf: bytearray, tag: int, value) -> None:
    if tag in (TAG_NULL, TAG_FALSE, TAG_TRUE):
        return  # no payload
    if tag == TAG_I64:
        if value < -(2**63) or value > 2**63 - 1:
            raise ValueError("integer out of i64 range")
        buf.extend(int(value).to_bytes(8, "little", signed=True))
        return
    if tag == TAG_F64:
        buf.extend(struct.pack("<d", float(value)))
        return
    if tag == TAG_STRING:
        sb = value.encode("utf-8")
        _write_varint(buf, len(sb))
        buf.extend(sb)
        return
    if tag == TAG_BYTES:
        b = bytes(value)
        _write_varint(buf, len(b))
        buf.extend(b)
        return
    if tag == TAG_ARRAY:
        body = _encode_array_body(list(value))
        buf.extend(len(body).to_bytes(4, "little"))
        buf.extend(body)
        return
    if tag == TAG_OBJECT:
        body = _encode_object_body(value)
        buf.extend(len(body).to_bytes(4, "little"))
        buf.extend(body)
        return
    raise ValueError(f"bad tag: {tag}")


# -------- decode --------

try:
    from . import _native as _native_mod  # type: ignore
    _decode_native = _native_mod.decode
    _encode_native = _native_mod.encode
except ImportError:
    _decode_native = None  # extension unavailable; fall through to Python
    _encode_native = None


def decode(data: bytes) -> dict:
    if _decode_native is not None:
        return _decode_native(data)
    if len(data) < 1:
        raise ValueError("truncated document")
    if data[0] != TAG_OBJECT:
        raise ValueError("top-level must be object")
    val, _ = _read_value(data, 0)
    if not isinstance(val, dict):
        raise ValueError("top-level must be object (dict)")
    return val


def _decode_pure_python(data: bytes) -> dict:
    """The pure-Python fallback. Kept callable for tests/benchmarks
    even when the native extension is loaded."""
    if len(data) < 1:
        raise ValueError("truncated document")
    if data[0] != TAG_OBJECT:
        raise ValueError("top-level must be object")
    val, _ = _read_value(data, 0)
    if not isinstance(val, dict):
        raise ValueError("top-level must be object (dict)")
    return val


def _read_value(buf: bytes, pos: int) -> tuple[object, int]:
    if pos >= len(buf):
        raise ValueError("truncated")
    tag = buf[pos]
    pos += 1
    return _read_payload(buf, pos, tag)


def _read_payload(buf: bytes, pos: int, tag: int) -> tuple[object, int]:
    if tag == TAG_NULL:
        return None, pos
    if tag == TAG_FALSE:
        return False, pos
    if tag == TAG_TRUE:
        return True, pos
    if tag == TAG_I64:
        if pos + 8 > len(buf):
            raise ValueError("truncated i64")
        (n,) = _UNPACK_I64(buf, pos)
        return n, pos + 8
    if tag == TAG_F64:
        if pos + 8 > len(buf):
            raise ValueError("truncated f64")
        (f,) = _UNPACK_F64(buf, pos)
        return f, pos + 8
    if tag == TAG_STRING:
        n, pos = _read_varint(buf, pos)
        end = pos + n
        if end > len(buf):
            raise ValueError("truncated string")
        return buf[pos:end].decode("utf-8"), end
    if tag == TAG_BYTES:
        n, pos = _read_varint(buf, pos)
        end = pos + n
        if end > len(buf):
            raise ValueError("truncated bytes")
        return bytes(buf[pos:end]), end
    if tag == TAG_ARRAY:
        if pos + 4 > len(buf):
            raise ValueError("truncated array length")
        (body_len,) = _UNPACK_U32(buf, pos)
        pos += 4
        end = pos + body_len
        if end > len(buf):
            raise ValueError("truncated array body")
        items = []
        while pos < end:
            v, pos = _read_value(buf, pos)
            items.append(v)
        return items, end
    if tag == TAG_OBJECT:
        if pos + 4 > len(buf):
            raise ValueError("truncated object length")
        body_len = int.from_bytes(buf[pos : pos + 4], "little")
        pos += 4
        end = pos + body_len
        if end > len(buf):
            raise ValueError("truncated object body")
        out: dict = {}
        while pos < end:
            entry_tag = buf[pos]
            pos += 1
            klen, pos = _read_varint(buf, pos)
            key_end = pos + klen
            if key_end > end:
                raise ValueError("truncated object key")
            key = buf[pos:key_end].decode("utf-8")
            pos = key_end
            value, pos = _read_payload(buf, pos, entry_tag)
            out[key] = value
        return out, end
    raise ValueError(f"unknown tag: {tag}")
