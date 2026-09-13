"""Source-agnostic comparators.

Every comparator returns a value in [0, 1] when both sides carry information,
and None when either does not. None means NEUTRAL. It must never be coerced to
0.0 by a caller: absence of evidence is not evidence of absence, and our local
data is sparse enough that the difference decides most matches.
"""

from __future__ import annotations

import math
from typing import Literal

from rapidfuzz import fuzz

Agreement = Literal["agree", "conflict", "absent"]

# Years decay on this scale: 10 years out scores about 0.37.
YEAR_DECAY = 10.0


def title_similarity(left: str, right: str) -> float:
    """Best-of-three rapidfuzz ratio, in [0, 1].

    No single comparator wins on both distortions titles actually show up
    with: token-set/token-sort ignore word order, so they recover a
    reordered title, but neither is built to look past a trailing subtitle
    the other side lacks. WRatio's blend of full- and partial-string ratios
    covers that case instead. Taking the max lets whichever comparator fits
    the pair carry the score, without needing fuzzy machinery in the
    blocking layer to know in advance which distortion it is looking at.
    """
    if not left or not right:
        return 0.0
    return (
        max(
            fuzz.token_set_ratio(left, right),
            fuzz.token_sort_ratio(left, right),
            fuzz.WRatio(left, right),
        )
        / 100.0
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
