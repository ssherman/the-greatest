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
