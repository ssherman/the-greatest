"""Stage 3: decide. accept / reject / ABSTAIN.

Abstain is first class. A wrong merge destroys data; an abstention costs a
review. The margin to the second-best candidate is the guard against the
specific failure that soured the first attempt -- confidently picking one of
five duplicate works. Popularity is a prior and tie-breaker, never identity
evidence.
"""

from __future__ import annotations

from typing import Literal

from pydantic import BaseModel

from openlibrary.matcher.scorer import ScoredCandidate, Weights

PRIOR_FEATURE = "popularity_prior"


class Decision(BaseModel):
    verdict: Literal["accept", "abstain", "reject"]
    work_key: str | None = None
    score: float | None = None
    margin: float | None = None
    reason: str


def _has_identity_evidence(candidate: ScoredCandidate) -> bool:
    """True if evidence contains any non-popularity identity feature with a non-None value."""
    for feature_name, feature_data in candidate.evidence.items():
        if feature_name != PRIOR_FEATURE and feature_data.get("value") is not None:
            return True
    return False


def rank(candidates: list[ScoredCandidate]) -> list[ScoredCandidate]:
    """Highest score first; ties broken by work_key so the order is deterministic."""
    return sorted(candidates, key=lambda c: (-c.score, c.work_key))


def decide(candidates: list[ScoredCandidate], weights: Weights) -> Decision:
    if not candidates:
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
            reason="no identity evidence: only the popularity prior is present",
        )

    if best.score < weights.reject_threshold:
        return Decision(
            verdict="reject",
            work_key=best.work_key,
            score=best.score,
            margin=margin,
            reason=f"best score {best.score:.3f} below reject threshold "
            f"{weights.reject_threshold:.3f}",
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
