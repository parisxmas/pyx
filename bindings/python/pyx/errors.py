"""Exception hierarchy for pyx."""
from __future__ import annotations


class PyxError(Exception):
    """Base class for pyx errors. Carries the C-side status code and the
    last-error message captured from the calling thread."""

    def __init__(self, status: int, message: str = ""):
        self.status = status
        self.message = message
        super().__init__(f"pyx error {status}: {message}")


class CorruptDb(PyxError):
    pass


class TxnAlreadyActive(PyxError):
    pass


class NoActiveTxn(PyxError):
    pass


class KeyTooLarge(PyxError):
    pass


class ValueTooLarge(PyxError):
    pass


class CollectionNameInvalid(PyxError):
    pass


class NoSuchIndex(PyxError):
    pass


class UnsupportedFieldType(PyxError):
    pass


def from_status(status: int, message: str = "") -> PyxError:
    """Construct a typed PyxError for a status code."""
    cls = _STATUS_TO_CLASS.get(status, PyxError)
    return cls(status, message)


_STATUS_TO_CLASS = {
    -4: CorruptDb,
    -5: TxnAlreadyActive,
    -6: NoActiveTxn,
    -7: KeyTooLarge,
    -8: ValueTooLarge,
    -9: CollectionNameInvalid,
    -10: NoSuchIndex,
    -11: UnsupportedFieldType,
}
