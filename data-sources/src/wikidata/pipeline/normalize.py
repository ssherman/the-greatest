"""Name and identifier normalization shared by the build and (later) the API.

The same functions run at build time and at query time: a divergence does not raise, it just
stops finding things.
"""

import re
import unicodedata

_NON_WORD = re.compile(r"[\W_]+")


def normalize_name(value: str) -> str:
    """NFKD, accents folded, casefolded, punctuation to spaces, whitespace collapsed."""
    decomposed = unicodedata.normalize("NFKD", value)
    stripped = "".join(ch for ch in decomposed if not unicodedata.combining(ch))
    return _NON_WORD.sub(" ", stripped.casefold()).strip()


def _isbn13_check(body12: str) -> str:
    total = sum(int(d) * (1 if i % 2 == 0 else 3) for i, d in enumerate(body12))
    return str((10 - total % 10) % 10)


def _isbn10_ok(isbn10: str) -> bool:
    total = sum((10 - i) * int(d) for i, d in enumerate(isbn10[:9]))
    total += 10 if isbn10[9] == "X" else int(isbn10[9])
    return total % 11 == 0


def _normalize_isbn(value: str) -> str | None:
    cleaned = re.sub(r"[\s-]", "", value).upper()
    if re.fullmatch(r"\d{9}[\dX]", cleaned):
        if not _isbn10_ok(cleaned):
            return None
        body = "978" + cleaned[:9]
        return body + _isbn13_check(body)
    if re.fullmatch(r"\d{13}", cleaned):
        return cleaned if _isbn13_check(cleaned[:12]) == cleaned[12] else None
    return None


def normalize_external_id(kind: str, value: str) -> str | None:
    """Canonical form of an identifier value, or None when it is not valid for its kind."""
    if kind == "isbn":
        return _normalize_isbn(value)
    if kind == "strip_spaces":
        return re.sub(r"\s+", "", value) or None
    if kind == "exact":
        return value or None
    raise ValueError(f"unknown external id normalizer: {kind}")
