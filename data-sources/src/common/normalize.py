"""The one normalization algorithm, in two representations.

Every fingerprint in this project comes from here. The Python functions and the
SQL expression builders MUST agree byte for byte -- the pipeline normalizes
41.5M rows in DuckDB, the API normalizes one query string in Python, and a
divergence between them does not raise, it just stops finding things.

Bump NORMALIZER_VERSION on any change. It is written into every build manifest
and every API response so "did the data change or did the code?" has an answer.
"""

from __future__ import annotations

import re
import unicodedata
from dataclasses import dataclass

NORMALIZER_VERSION = 1

# Below this length a fingerprint is not usable as a blocking key. Measured:
# 3,360 of 126,330 books (2.7%) normalize to fewer than 4 characters, and one
# of them ("!!!" -> "") produced a 604,144-row join.
MIN_BLOCKING_FP_LENGTH = 4

# Cut a subtitle at the first colon, semicolon or opening parenthesis.
_SUBTITLE_CUT = re.compile(r"^([^:;(]*)")

# English only, and deliberately so -- see the test for the reasoning.
_LEADING_ARTICLE = re.compile(r"^(?:the|a|an) ")

_NON_FINGERPRINT_CHAR = re.compile(r"[^a-z0-9 ]")
_RUNS_OF_SPACES = re.compile(r" +")


def fingerprint(value: str | None) -> str:
    """Fold accents, lowercase, replace every other character with a space, collapse."""
    if not value:
        return ""
    decomposed = unicodedata.normalize("NFD", value)
    stripped = "".join(ch for ch in decomposed if not unicodedata.combining(ch))
    lowered = stripped.lower()
    spaced = _NON_FINGERPRINT_CHAR.sub(" ", lowered)
    return _RUNS_OF_SPACES.sub(" ", spaced).strip()


@dataclass(frozen=True)
class TitleFingerprints:
    """Three fingerprints per title.

    No single normalization wins: measured Jaccard handled reordering (0.929)
    and failed on subtitles (0.44); Jaro-Winkler did the reverse. Storing the
    variants turns near-misses into exact hits without fuzzy machinery.
    """

    full: str
    nosub: str
    noart: str


def title_fingerprints(title: str | None) -> TitleFingerprints:
    full = fingerprint(title)

    # The cut happens on the RAW title: normalization has already removed the
    # colon by the time the fingerprint exists.
    cut = _SUBTITLE_CUT.match(title or "")
    nosub = fingerprint(cut.group(1)) if cut else ""
    if len(nosub) < MIN_BLOCKING_FP_LENGTH:
        nosub = full

    noart = _LEADING_ARTICLE.sub("", full)
    if len(noart) < MIN_BLOCKING_FP_LENGTH:
        noart = full

    return TitleFingerprints(full=full, nosub=nosub, noart=noart)


def name_fingerprint(name: str | None) -> str:
    return fingerprint(name)


def fingerprint_sql(expr: str) -> str:
    """The SQL twin of `fingerprint`. `expr` is a SQL expression, not a literal."""
    return (
        "regexp_replace(trim(regexp_replace(lower(strip_accents("
        f"{expr}"
        ")), '[^a-z0-9 ]', ' ', 'g')), ' +', ' ', 'g')"
    )


def title_nosub_sql(expr: str) -> str:
    """The SQL twin of `TitleFingerprints.nosub`, including the degenerate fallback."""
    full = fingerprint_sql(expr)
    cut = fingerprint_sql(f"regexp_extract({expr}, '^([^:;(]*)', 1)")
    return f"CASE WHEN length({cut}) >= {MIN_BLOCKING_FP_LENGTH} THEN {cut} ELSE {full} END"


def title_noart_sql(expr: str) -> str:
    """The SQL twin of `TitleFingerprints.noart`, including the degenerate fallback."""
    full = fingerprint_sql(expr)
    stripped = f"regexp_replace({full}, '^(the|a|an) ', '')"
    return (
        f"CASE WHEN length({stripped}) >= {MIN_BLOCKING_FP_LENGTH} THEN {stripped} ELSE {full} END"
    )


IDENTIFIER_TYPES = ("isbn13", "isbn10", "oclc", "lccn", "asin", "goodreads")

_NON_ALNUM = re.compile(r"[^0-9A-Za-z]")
_OCLC_PREFIX = re.compile(r"^(?:\(ocolc\)|ocm|ocn|on)", re.IGNORECASE)
_LCCN_SUFFIX = re.compile(r"//.*$")
_DIGITS = re.compile(r"\d+")


@dataclass(frozen=True)
class NormalizedIsbn:
    isbn13: str | None
    isbn10: str | None
    checksum_ok: bool


def _isbn10_check_digit(body: str) -> str:
    total = sum((10 - i) * int(ch) for i, ch in enumerate(body))
    remainder = (11 - (total % 11)) % 11
    return "X" if remainder == 10 else str(remainder)


def _isbn13_check_digit(body: str) -> str:
    total = sum(int(ch) * (1 if i % 2 == 0 else 3) for i, ch in enumerate(body))
    return str((10 - (total % 10)) % 10)


def normalize_isbn(raw: str | None) -> NormalizedIsbn | None:
    if not raw:
        return None
    cleaned = _NON_ALNUM.sub("", str(raw)).upper()

    if len(cleaned) == 10 and cleaned[:9].isdigit() and (cleaned[9].isdigit() or cleaned[9] == "X"):
        ok = _isbn10_check_digit(cleaned[:9]) == cleaned[9]
        body13 = "978" + cleaned[:9]
        return NormalizedIsbn(
            isbn13=body13 + _isbn13_check_digit(body13) if ok else None,
            isbn10=cleaned,
            checksum_ok=ok,
        )

    if len(cleaned) == 13 and cleaned.isdigit():
        ok = _isbn13_check_digit(cleaned[:12]) == cleaned[12]
        isbn10 = None
        if ok and cleaned.startswith("978"):
            body10 = cleaned[3:12]
            isbn10 = body10 + _isbn10_check_digit(body10)
        return NormalizedIsbn(isbn13=cleaned, isbn10=isbn10, checksum_ok=ok)

    return None


def normalize_oclc(raw: str | None) -> str | None:
    if not raw:
        return None
    cleaned = _OCLC_PREFIX.sub("", str(raw).strip())
    cleaned = _NON_ALNUM.sub("", cleaned)
    if not cleaned.isdigit():
        return None
    stripped = cleaned.lstrip("0")
    return stripped or "0"


def normalize_lccn(raw: str | None) -> str | None:
    if not raw:
        return None
    value = _LCCN_SUFFIX.sub("", str(raw)).replace(" ", "")
    if "-" in value:
        head, _, tail = value.partition("-")
        value = head + tail.zfill(6) if tail.isdigit() else head + tail
    value = _NON_ALNUM.sub("", value).lower()
    return value or None


def normalize_asin(raw: str | None) -> str | None:
    if not raw:
        return None
    cleaned = _NON_ALNUM.sub("", str(raw)).upper()
    return cleaned if len(cleaned) == 10 else None


def normalize_goodreads(raw: str | None) -> str | None:
    """[GOODREADS] Goodreads ids arrive both bare ("4671") and slugged
    ("4671.The_Great_Gatsby"); only the leading integer identifies the book."""
    if not raw:
        return None
    match = _DIGITS.match(str(raw).strip())
    return match.group(0) if match else None


def _isbn_clean_sql(expr: str) -> str:
    return f"upper(regexp_replace({expr}, '[^0-9A-Za-z]', '', 'g'))"


def _isbn10_check_sql(body: str) -> str:
    """Check character for a 9-digit ISBN-10 body; 'X' for remainder 10."""
    weighted = (
        f"list_sum(list_transform(range(0, 9), i -> "
        f"(10 - i) * CAST(substr({body}, CAST(i AS INT) + 1, 1) AS INTEGER)))"
    )
    remainder = f"((11 - ({weighted} % 11)) % 11)"
    return f"CASE WHEN {remainder} = 10 THEN 'X' ELSE CAST({remainder} AS VARCHAR) END"


def _isbn13_check_sql(body: str) -> str:
    """Check digit for a 12-digit ISBN-13 body."""
    weighted = (
        f"list_sum(list_transform(range(0, 12), i -> "
        f"CAST(substr({body}, CAST(i AS INT) + 1, 1) AS INTEGER) * "
        f"CASE WHEN i % 2 = 0 THEN 1 ELSE 3 END))"
    )
    return f"CAST(((10 - ({weighted} % 10)) % 10) AS VARCHAR)"


def isbn_checksum_ok_sql(expr: str) -> str:
    v = _isbn_clean_sql(expr)
    is10 = f"(length({v}) = 10 AND regexp_matches({v}, '^[0-9]{{9}}[0-9X]$'))"
    is13 = f"(length({v}) = 13 AND regexp_matches({v}, '^[0-9]{{13}}$'))"
    ok10 = f"({_isbn10_check_sql(f'substr({v}, 1, 9)')} = substr({v}, 10, 1))"
    ok13 = f"({_isbn13_check_sql(f'substr({v}, 1, 12)')} = substr({v}, 13, 1))"
    return f"CASE WHEN {is10} THEN {ok10} WHEN {is13} THEN {ok13} ELSE NULL END"


def isbn13_sql(expr: str) -> str:
    v = _isbn_clean_sql(expr)
    is10 = f"(length({v}) = 10 AND regexp_matches({v}, '^[0-9]{{9}}[0-9X]$'))"
    is13 = f"(length({v}) = 13 AND regexp_matches({v}, '^[0-9]{{13}}$'))"
    ok10 = f"({_isbn10_check_sql(f'substr({v}, 1, 9)')} = substr({v}, 10, 1))"
    ok13 = f"({_isbn13_check_sql(f'substr({v}, 1, 12)')} = substr({v}, 13, 1))"
    body13 = f"('978' || substr({v}, 1, 9))"
    return (
        f"CASE WHEN {is10} AND {ok10} THEN {body13} || {_isbn13_check_sql(body13)} "
        f"WHEN {is13} THEN CASE WHEN {ok13} THEN {v} ELSE {v} END "
        f"ELSE NULL END"
    )


def isbn10_sql(expr: str) -> str:
    v = _isbn_clean_sql(expr)
    is10 = f"(length({v}) = 10 AND regexp_matches({v}, '^[0-9]{{9}}[0-9X]$'))"
    is13 = f"(length({v}) = 13 AND regexp_matches({v}, '^[0-9]{{13}}$'))"
    ok13 = f"({_isbn13_check_sql(f'substr({v}, 1, 12)')} = substr({v}, 13, 1))"
    body10 = f"substr({v}, 4, 9)"
    return (
        f"CASE WHEN {is10} THEN {v} "
        f"WHEN {is13} AND {ok13} AND starts_with({v}, '978') "
        f"THEN {body10} || {_isbn10_check_sql(body10)} "
        f"ELSE NULL END"
    )


def oclc_sql(expr: str) -> str:
    stripped = (
        f"regexp_replace(regexp_replace(trim({expr}), "
        f"'^(?i)(\\(ocolc\\)|ocm|ocn|on)', ''), '[^0-9A-Za-z]', '', 'g')"
    )
    digits_only = f"regexp_matches({stripped}, '^[0-9]+$')"
    unpadded = f"regexp_replace({stripped}, '^0+', '')"
    return (
        f"CASE WHEN {digits_only} THEN "
        f"CASE WHEN {unpadded} = '' THEN '0' ELSE {unpadded} END ELSE NULL END"
    )


def lccn_sql(expr: str) -> str:
    base = f"replace(regexp_replace({expr}, '//.*$', ''), ' ', '')"
    head = f"regexp_extract({base}, '^([^-]*)-', 1)"
    tail = f"regexp_extract({base}, '^[^-]*-(.*)$', 1)"
    # `lpad(tail, 6, '0')` alone TRUNCATES a tail longer than 6 characters from
    # the right (lpad('1234567', 6, '0') -> '123456'), unlike Python's
    # `tail.zfill(6)`, which only pads and never shortens. Left unpadded,
    # "n 78-8903510" -- a 7-digit tail -- wrote "n78890351" here while the
    # Python side normalized the same string to "n788903510": a silent parity
    # break in the one module whose entire purpose is SQL/Python agreement.
    # Only pad when the tail is actually shorter than 6; leave a longer tail
    # intact, matching `zfill`.
    padded_tail = f"CASE WHEN length({tail}) >= 6 THEN {tail} ELSE lpad({tail}, 6, '0') END"
    joined = (
        f"CASE WHEN contains({base}, '-') THEN "
        f"CASE WHEN regexp_matches({tail}, '^[0-9]+$') "
        f"THEN {head} || {padded_tail} ELSE {head} || {tail} END "
        f"ELSE {base} END"
    )
    cleaned = f"lower(regexp_replace({joined}, '[^0-9A-Za-z]', '', 'g'))"
    return f"CASE WHEN {cleaned} = '' THEN NULL ELSE {cleaned} END"


def asin_sql(expr: str) -> str:
    cleaned = f"upper(regexp_replace({expr}, '[^0-9A-Za-z]', '', 'g'))"
    return f"CASE WHEN length({cleaned}) = 10 THEN {cleaned} ELSE NULL END"


def goodreads_sql(expr: str) -> str:
    """[GOODREADS]"""
    digits = f"regexp_extract(trim({expr}), '^([0-9]+)', 1)"
    return f"CASE WHEN {digits} = '' THEN NULL ELSE {digits} END"
