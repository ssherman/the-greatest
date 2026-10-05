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

Identity first (2026-10-04 list-queries spec, section 3). A title-less
candidate -- a translation whose non-Latin title fingerprints to "" -- matched
on the author alone, so it can neither outrank a candidate that has a title or
identifier nor set the margin of one. `rank` puts identity-bearing candidates
first and `margins` ignores title-less candidates below; with nothing but
title-less candidates the decision still abstains for no identity evidence.
Measured in the 2026-10-04 spike: 26 margin abstains and 8 displaced top
candidates came from this.
"""

from __future__ import annotations

from collections.abc import Sequence
from typing import TYPE_CHECKING, Literal

from pydantic import BaseModel, Field

from openlibrary.matcher.scorer import (
    IDENTIFIER_FEATURE,  # noqa: F401 (re-exported; moved to the scorer)
    IDENTITY_FEATURES,  # noqa: F401
    ScoredCandidate,
    Weights,
    has_identity_evidence,
)

if TYPE_CHECKING:
    from openlibrary.matcher.cluster import ClusterIndex

PRIOR_FEATURE = "popularity_prior"


class Decision(BaseModel):
    verdict: Literal["accept", "abstain", "reject"]
    work_key: str | None = None
    score: float | None = None
    margin: float | None = None
    reason: str
    # The other members of the winning duplicate cluster (2026-10-04 spec, section 4).
    duplicates: list[str] = Field(default_factory=list)


_has_identity_evidence = has_identity_evidence


def _group(candidate: ScoredCandidate, clusters: ClusterIndex | None) -> tuple[str, float, bool]:
    """(group id, group best score, is representative) -- a singleton group
    when unclustered."""
    if clusters is None or candidate.work_key not in clusters.of:
        return candidate.work_key, candidate.score, True
    cid = clusters.of[candidate.work_key]
    return cid, clusters.best_score[cid], clusters.representative.get(cid) == candidate.work_key


def rank(
    candidates: list[ScoredCandidate], clusters: ClusterIndex | None = None
) -> list[ScoredCandidate]:
    """Identity-bearing candidates first (2026-10-04 spec, section 3), then by
    their group's best score, groups kept together with the representative
    first, then score, then work_key -- deterministic."""

    def key(c: ScoredCandidate):
        cid, best, is_rep = _group(c, clusters)
        return (not has_identity_evidence(c), -best, cid, not is_rep, -c.score, c.work_key)

    return sorted(candidates, key=key)


def _margin_at(ranked: list[ScoredCandidate], i: int, clusters: ClusterIndex | None) -> float:
    cid, best, _ = _group(ranked[i], clusters)
    below = [
        c.score
        for c in ranked[i + 1 :]
        if has_identity_evidence(c) and _group(c, clusters)[0] != cid
    ]
    return best - max(below, default=0.0)


def margins(ranked: list[ScoredCandidate], clusters: ClusterIndex | None = None) -> list[float]:
    """Per candidate: its group's best score minus the best score among
    identity-bearing candidates ranked below it in a different group (0.0 if
    none). A candidate that could not itself be accepted never sets another's
    margin. margins(...)[0] is the decision's margin (R85)."""
    return [_margin_at(ranked, i, clusters) for i in range(len(ranked))]


def decide(
    candidates: list[ScoredCandidate],
    weights: Weights,
    *,
    volume_guards_tripped: Sequence[str] = (),
    clusters: ClusterIndex | None = None,
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

    ordered = rank(candidates, clusters)
    best = ordered[0]
    margin = _margin_at(ordered, 0, clusters)

    cid = clusters.of.get(best.work_key) if clusters else None
    group = clusters.members.get(cid, [best.work_key]) if clusters and cid else [best.work_key]
    if len(group) > 1 and has_identity_evidence(best):
        rep_key = clusters.representative.get(cid)
        if rep_key is None:
            return Decision(
                verdict="abstain",
                work_key=best.work_key,
                score=clusters.best_score[cid],
                margin=margin,
                reason="duplicate cluster with no dominant member: " + ", ".join(group),
                duplicates=[k for k in group if k != best.work_key],
            )
        representative = next(c for c in ordered if c.work_key == rep_key)
        score = clusters.best_score[cid]
        duplicates = [k for k in group if k != rep_key]
    else:
        representative, score, duplicates = best, best.score, []
    runner_up = score - margin

    if representative.conflicts:
        return Decision(
            verdict="abstain",
            work_key=representative.work_key,
            score=score,
            margin=margin,
            reason="identifier conflict on the best candidate: "
            + ", ".join(representative.conflicts),
            duplicates=duplicates,
        )

    if not _has_identity_evidence(representative):
        return Decision(
            verdict="abstain",
            work_key=representative.work_key,
            score=score,
            margin=margin,
            reason="no identity evidence: only author/year/language/popularity are present",
            duplicates=duplicates,
        )

    if score < weights.reject_threshold:
        below = f"best score {score:.3f} below reject threshold {weights.reject_threshold:.3f}"
        if volume_guards_tripped:
            return Decision(
                verdict="abstain",
                work_key=representative.work_key,
                score=score,
                margin=margin,
                reason=f"{below}; search refused for volume: {', '.join(volume_guards_tripped)}",
                duplicates=duplicates,
            )
        return Decision(
            verdict="reject",
            work_key=representative.work_key,
            score=score,
            margin=margin,
            reason=below,
            duplicates=duplicates,
        )

    if score >= weights.accept_threshold and margin >= weights.margin_threshold:
        return Decision(
            verdict="accept",
            work_key=representative.work_key,
            score=score,
            margin=margin,
            reason=f"score {score:.3f} with margin {margin:.3f}",
            duplicates=duplicates,
        )

    if score >= weights.accept_threshold:
        return Decision(
            verdict="abstain",
            work_key=representative.work_key,
            score=score,
            margin=margin,
            reason=f"margin {margin:.3f} below threshold {weights.margin_threshold:.3f}; "
            f"runner-up scores {runner_up:.3f}",
            duplicates=duplicates,
        )

    return Decision(
        verdict="abstain",
        work_key=representative.work_key,
        score=score,
        margin=margin,
        reason=f"score {score:.3f} between reject and accept thresholds",
        duplicates=duplicates,
    )
