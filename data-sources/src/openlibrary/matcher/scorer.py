"""Stage 2: score. Never decides.

A weighted mean over the features that are PRESENT, minus conflict penalties.
Absent features touch neither numerator nor denominator, which is what makes
"absence is neutral" true in the arithmetic and not merely in the comment.

Weights are learned offline (Task 27, `openlibrary.eval.calibrate`) and loaded
from weights.json: a seeded random coordinate search over the labelled set did
the learning (`method: "random-search"` in the file). Splink was evaluated for
the job and could not consume pair-level features -- see `calibrate.splink_weights`.
This scorer carries the learned numbers, so the batch pass and the interactive
path agree by construction.
"""

from __future__ import annotations

import json
from pathlib import Path

from pydantic import BaseModel, Field, model_validator

from openlibrary.matcher.blocking import BlockingQuery
from openlibrary.matcher.features import FEATURES, WorkView, conflicts, extract

MATCHER_VERSION = 1
WEIGHTS_PATH = Path(__file__).parent / "weights.json"


class Weights(BaseModel):
    matcher_version: int
    calibrated: bool
    calibrated_at: str | None = None
    # How the numbers were fitted ("random-search"); None for the uncalibrated
    # placeholder `calibrate.equal_weights()`.
    method: str | None = None
    feature_weights: dict[str, float]
    conflict_penalties: dict[str, float] = Field(default_factory=dict)
    accept_threshold: float
    reject_threshold: float
    margin_threshold: float

    # A typo in weights.json (Task 27 rewrites this file after every
    # calibration run) must fail LOUDLY at load time. Silently defaulting an
    # unrecognized key to being ignored, or a missing key to weight 0.0 via
    # `.get(name, 0.0)` in the scorer, would weight that feature at zero
    # everywhere without anyone noticing -- the failure mode this validator
    # exists to rule out.
    @model_validator(mode="after")
    def _feature_weights_match_declared_features(self) -> Weights:
        declared = set(FEATURES)
        present = set(self.feature_weights)
        missing = declared - present
        unknown = present - declared
        if missing or unknown:
            problems = []
            if missing:
                problems.append(f"missing keys: {sorted(missing)}")
            if unknown:
                problems.append(f"unknown keys: {sorted(unknown)}")
            raise ValueError(
                "feature_weights must have exactly the keys declared in "
                f"FEATURES ({'; '.join(problems)})"
            )
        return self


class ScoredCandidate(BaseModel):
    work_key: str
    score: float
    rules: list[str] = Field(default_factory=list)
    evidence: dict[str, dict] = Field(default_factory=dict)
    conflicts: list[str] = Field(default_factory=list)


def load_weights(path: Path | None = None) -> Weights:
    return Weights.model_validate(json.loads(Path(path or WEIGHTS_PATH).read_text()))


def score_features(
    work_key: str,
    values: dict[str, float | None],
    found_conflicts: list[str],
    rules: list[str],
    weights: Weights,
) -> ScoredCandidate:
    """The weighted-mean-minus-penalties arithmetic, on already-extracted inputs.

    Split out of `score_candidate` (Task 26b) so that the calibration search
    (Task 27) can call `prepare` once per split -- blocking, `load_work_views`,
    `extract` and `conflicts`, ~4.5s/case, almost all DuckDB -- and then call
    this, pure Python, thousands of times per weight vector without touching
    DuckDB again.
    """
    numerator = 0.0
    denominator = 0.0
    evidence: dict[str, dict] = {}
    for name, value in values.items():
        weight = weights.feature_weights.get(name, 0.0)
        if value is None:
            evidence[name] = {"value": None, "weight": weight, "contribution": 0.0}
            continue
        contribution = weight * value
        numerator += contribution
        denominator += weight
        evidence[name] = {"value": value, "weight": weight, "contribution": contribution}

    base = numerator / denominator if denominator else 0.0
    penalty = sum(weights.conflict_penalties.get(name, 0.0) for name in found_conflicts)
    score = max(0.0, min(1.0, base - penalty))

    return ScoredCandidate(
        work_key=work_key,
        score=score,
        rules=list(rules),
        evidence=evidence,
        conflicts=found_conflicts,
    )


def score_candidate(
    query: BlockingQuery,
    work: WorkView,
    rules: list[str],
    weights: Weights,
    *,
    identifier_hits: frozenset[str] = frozenset(),
) -> ScoredCandidate:
    values = extract(query, work, identifier_hits=identifier_hits)
    found_conflicts = conflicts(query, work, identifier_hits=identifier_hits)
    return score_features(work.work_key, values, found_conflicts, rules, weights)
