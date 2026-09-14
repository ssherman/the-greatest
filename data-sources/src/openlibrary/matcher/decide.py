"""Stage 3: decide. accept / reject / ABSTAIN.

Abstain is first class. A wrong merge destroys data; an abstention costs a
review. The margin to the second-best candidate is the guard against the
specific failure that soured the first attempt -- confidently picking one of
five duplicate works. Popularity is a prior and tie-breaker, never identity
evidence.

Identity evidence is TITLE or IDENTIFIER (ruling R58). Author agreement
identifies the author, not the book: with author_overlap and
author_name_similarity carrying two of the largest calibrated weights, a
candidate reached through an author shelf whose title could not be compared
(a Bengali or Cyrillic title against a Latin fingerprint) scored 0.91-0.95
on author agreement alone and was accepted -- `degenerate_title-013` and
`pseudonym_or_alt_name-001`, both labelled `no_match`, were 2 of the 3
false merges of the v1 calibration. Year, language and popularity are
priors of the same kind: they can raise or lower a score, never carry an
accept on their own. `IDENTITY_FEATURES` is the allow-list; the earlier
guard (R42) was "anything but popularity", which let those cases through.

A refused search is not a negative (ruling R59). When a rule's volume cap
tripped -- an author shelf over `MAX_SHELF_SIZE`, an identifier on more than
`MAX_CANDIDATES_PER_RULE` works -- there WAS something there that the matcher
declined to fetch, and `reject` would record "not in Open Library" as fact.
That holds with zero candidates (`degenerate_title-014`: Agatha Christie,
Cyrillic title, shelf 1,226 > 500 -- the v1 false reject) and equally when
the only candidates are weak: `no_candidates-030` ("Donne Innamorate", D.H.
Lawrence's shelf refused) reached the reject band on 200 rule-6 fallbacks,
none of them the book, best 0.397 against a 0.4 threshold. Below the reject
threshold means "not found" only when the search was allowed to look, so a
tripped volume guard turns the reject band into an abstain too. Accept and
the middle band are untouched: a clear winner among the candidates that
WERE fetched is still a clear winner.
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import Literal

from pydantic import BaseModel

from openlibrary.matcher.scorer import ScoredCandidate, Weights

PRIOR_FEATURE = "popularity_prior"

# The features whose PRESENCE (any non-None value) says the two sides were
# actually compared as books, not merely as the work of the same author.
# `identifier_agreement` is deliberately not here: it is identity evidence
# only when it AGREES (1.0) -- a 0.0 is a conflict, already handled first.
IDENTITY_FEATURES = ("title_similarity", "title_variant_exact", "subtitle_agreement")
IDENTIFIER_FEATURE = "identifier_agreement"


class Decision(BaseModel):
    verdict: Literal["accept", "abstain", "reject"]
    work_key: str | None = None
    score: float | None = None
    margin: float | None = None
    reason: str


def _has_identity_evidence(candidate: ScoredCandidate) -> bool:
    """True when a title feature is present or the identifier agrees (R58).

    Author agreement, year, language and popularity do not count: any
    combination of them alone -- however high the weighted mean -- abstains.
    """
    evidence = candidate.evidence
    if any(evidence.get(name, {}).get("value") is not None for name in IDENTITY_FEATURES):
        return True
    return evidence.get(IDENTIFIER_FEATURE, {}).get("value") == 1.0


def rank(candidates: list[ScoredCandidate]) -> list[ScoredCandidate]:
    """Highest score first; ties broken by work_key so the order is deterministic."""
    return sorted(candidates, key=lambda c: (-c.score, c.work_key))


def decide(
    candidates: list[ScoredCandidate],
    weights: Weights,
    *,
    volume_guards_tripped: Sequence[str] = (),
) -> Decision:
    """accept / abstain / reject over already-scored candidates.

    `volume_guards_tripped` is `BlockingResult.volume_guards_tripped`: the
    blocking rules whose volume CAP fired. It is what separates "not found"
    (reject) from "found too much to fetch" (abstain, R59) -- both with no
    candidates at all and when every candidate scores under the reject
    threshold. An empty or too-short title fingerprint is NOT a volume guard
    -- it has zero hits, and with nothing else firing the honest answer is
    still "not found".
    """
    if not candidates:
        if volume_guards_tripped:
            return Decision(
                verdict="abstain",
                reason="no candidates; search refused for volume: "
                + ", ".join(volume_guards_tripped),
            )
        return Decision(verdict="reject", reason="no candidates")

    ordered = rank(candidates)
    best = ordered[0]
    runner_up = ordered[1].score if len(ordered) > 1 else 0.0
    margin = best.score - runner_up

    if best.conflicts:
        return Decision(
            verdict="abstain",
            work_key=best.work_key,
            score=best.score,
            margin=margin,
            reason=f"identifier conflict on the best candidate: {', '.join(best.conflicts)}",
        )

    if not _has_identity_evidence(best):
        return Decision(
            verdict="abstain",
            work_key=best.work_key,
            score=best.score,
            margin=margin,
            reason="no identity evidence: only author/year/language/popularity are present",
        )

    if best.score < weights.reject_threshold:
        below = f"best score {best.score:.3f} below reject threshold {weights.reject_threshold:.3f}"
        if volume_guards_tripped:
            return Decision(
                verdict="abstain",
                work_key=best.work_key,
                score=best.score,
                margin=margin,
                reason=f"{below}; search refused for volume: {', '.join(volume_guards_tripped)}",
            )
        return Decision(
            verdict="reject",
            work_key=best.work_key,
            score=best.score,
            margin=margin,
            reason=below,
        )

    if best.score >= weights.accept_threshold and margin >= weights.margin_threshold:
        return Decision(
            verdict="accept",
            work_key=best.work_key,
            score=best.score,
            margin=margin,
            reason=f"score {best.score:.3f} with margin {margin:.3f}",
        )

    if best.score >= weights.accept_threshold:
        return Decision(
            verdict="abstain",
            work_key=best.work_key,
            score=best.score,
            margin=margin,
            reason=f"margin {margin:.3f} below threshold {weights.margin_threshold:.3f}; "
            f"runner-up scores {runner_up:.3f}",
        )

    return Decision(
        verdict="abstain",
        work_key=best.work_key,
        score=best.score,
        margin=margin,
        reason=f"score {best.score:.3f} between reject and accept thresholds",
    )
