"""Source-agnostic comparators.

The NUMERIC comparators (`fuzzy_similarity`, `compare_titles`, `set_overlap`,
`year_agreement`) return a value in [0, 1] when both sides carry information, and None when
either does not; `identifier_agreement` returns an `Agreement` literal
instead, with `"absent"` playing the same role. None (or "absent") means
NEUTRAL and must never be coerced to a disagreement score by a caller:
absence of evidence is not evidence of absence, and our local data is sparse
enough that the difference decides most matches.
"""

from __future__ import annotations

import math
from collections.abc import Iterable
from dataclasses import dataclass
from typing import Literal

from rapidfuzz import fuzz

Agreement = Literal["agree", "conflict", "absent"]

# Years decay on this scale: 10 years out scores about 0.37.
YEAR_DECAY = 10.0


def fuzzy_similarity(left: str, right: str) -> float | None:
    """Best-of-three rapidfuzz ratio, in [0, 1], or None when either
    fingerprint is empty.

    No single comparator wins on both distortions titles actually show up
    with: token-set/token-sort ignore word order, so they recover a
    reordered title, but neither is built to look past a trailing subtitle
    the other side lacks. WRatio's blend of full- and partial-string ratios
    covers that case instead. Taking the max lets whichever comparator fits
    the pair carry the score, without needing fuzzy machinery in the
    blocking layer to know in advance which distortion it is looking at.

    An empty fingerprint is ABSENCE, not disagreement (ruling R40): a
    punctuation-only title fingerprints to "", and scoring that as 0.0 would
    read as strong disagreement rather than as no title information at all.

    No longer used for titles (see `compare_titles`); it serves author names
    and subtitles, where token-set's subset credit is wanted ("tolkien" vs
    "j r r tolkien").
    """
    if not left or not right:
        return None
    return (
        max(
            fuzz.token_set_ratio(left, right),
            fuzz.token_sort_ratio(left, right),
            fuzz.WRatio(left, right),
        )
        / 100.0
    )


# A match through a query variant that only exists after the subtitle cut
# counts for at most this: the colon may be part of the title ("Star Wars: A
# New Hope"), and a full-title match must outrank it (2026-10-04 spec, section 2).
DERIVED_TITLE_FACTOR = 0.95


@dataclass(frozen=True)
class TitleComparison:
    similarity: float | None
    exact: float | None
    containment: bool


def _strictly_contains(a: str, b: str) -> bool:
    left, right = set(a.split()), set(b.split())
    return left != right and (left < right or right < left)


def compare_titles(
    whole: Iterable[str], derived: Iterable[str], work_variants: Iterable[str]
) -> TitleComparison:
    """Variant-aware, length-sensitive title comparison (replaces the
    token-set/WRatio max for titles: "Dune" vs "Children of Dune" was 1.0, and
    any shared word was 0.855 -- 2026-10-04 spec, D1).

    `similarity`: the best token_sort ratio over (query variant, work variant)
    pairs, derived pairs scaled by DERIVED_TITLE_FACTOR. `exact`: 1.0 when any
    query variant equals any work variant, else 0.0. `containment`: some pair
    is a strict token subset -- the scorer may grant it calibrated credit.
    None/None/False when either side has no fingerprint (R40: absence).
    """
    works = {w for w in work_variants if w}
    whole_set, derived_set = set(whole), set(derived)
    ours = whole_set | derived_set
    if not works or not ours:
        return TitleComparison(similarity=None, exact=None, containment=False)
    best = 0.0
    for q in whole_set:
        for w in works:
            best = max(best, fuzz.token_sort_ratio(q, w) / 100.0)
    for q in derived_set:
        for w in works:
            best = max(best, DERIVED_TITLE_FACTOR * fuzz.token_sort_ratio(q, w) / 100.0)
    return TitleComparison(
        similarity=best,
        exact=1.0 if ours & works else 0.0,
        containment=any(_strictly_contains(q, w) for q in ours for w in works),
    )


def set_overlap(left: set[str], right: set[str]) -> float | None:
    """Fraction of the SMALLER side that appears in the other.

    Asymmetric on purpose: we hold 1.004 authors per book, so a candidate with
    three authors must not be penalised for the two we never recorded.
    """
    if not left or not right:
        return None
    return len(left & right) / min(len(left), len(right))


def year_agreement(year: int | None, low: int | None, high: int | None) -> float | None:
    """Distance to a RANGE, not to a point.

    89% of works carry no publication date, and the edition years that stand in
    for it are a spread rather than an answer.
    """
    if year is None:
        return None
    bounds = [b for b in (low, high) if b is not None]
    if not bounds:
        return None
    lo, hi = min(bounds), max(bounds)
    if lo <= year <= hi:
        return 1.0
    distance = lo - year if year < lo else year - hi
    return math.exp(-distance / YEAR_DECAY)


def identifier_agreement(ours: set[str], theirs: set[str]) -> Agreement:
    """The only feature family that can produce NEGATIVE evidence.

    Source-agnostic: `ours` and `theirs` are whatever the caller is
    comparing -- this function only knows about set membership. The matcher
    (openlibrary.matcher.features) passes WORK KEYS, not raw identifier
    values: the set of works its identifiers reached during blocking, and
    the single candidate work under scoring. See that module for why a
    raw-identifier-set comparison was measured and rejected.
    """
    if not ours or not theirs:
        return "absent"
    return "agree" if ours & theirs else "conflict"
