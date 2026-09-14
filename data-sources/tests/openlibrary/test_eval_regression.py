"""The labeled set as a regression suite (Task 28).

The service is a pure function of `(request, source_version)`, so once the
matcher and the labeled set both exist, a change in the matcher's answers is
either a code change or a data change -- and these thresholds are what makes
that difference visible. They are pinned from the measured numbers of the
final calibration run (`thresholds.json`'s `measured` block), with headroom
in the safe direction, never from ambition.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from openlibrary.eval.dataset import load_cases
from openlibrary.eval.harness import THRESHOLDS_PATH, evaluate, read_prepared_cache, run
from openlibrary.matcher.scorer import MATCHER_VERSION, load_weights
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths

# bound key -> the direction that is safe: "min" means the metric must be at
# least this bound, "max" means at most. Mirrors gates.threshold_failures's
# five checks plus the false-reject bound this test also pins.
_DIRECTIONS = {
    "min_candidate_recall_10": "min",
    "max_false_merge_rate": "max",
    "min_precision_at_accept": "min",
    "max_abstention_rate": "max",
    "min_correct_no_match_rate": "min",
    "max_false_reject_rate": "max",
}


def _thresholds() -> dict:
    return json.loads(THRESHOLDS_PATH.read_text())


def test_thresholds_are_recorded_with_the_matcher_version_they_were_measured_on():
    data = _thresholds()
    assert data["matcher_version"] == MATCHER_VERSION, (
        "the matcher changed since these thresholds were measured; re-measure "
        "with the harness rather than editing the numbers"
    )
    assert data["dump_date"]
    assert data["measured_at"]


def test_every_threshold_has_a_measured_sibling_within_its_headroom():
    """The "measured, not aspirational" invariant, checked in code: each pinned
    bound must sit on the safe side of the value it was measured from -- a
    minimum at or below what was measured, a maximum at or above it."""
    data = _thresholds()
    measured = data["measured"]
    assert set(measured) == set(_DIRECTIONS)
    for key, direction in _DIRECTIONS.items():
        bound = data[key]
        value = measured[key]
        if direction == "min":
            assert bound <= value, f"{key}: pinned {bound} above its own measured {value}"
        else:
            assert bound >= value, f"{key}: pinned {bound} below its own measured {value}"


@pytest.mark.artifact
def test_the_matcher_does_not_regress_against_the_labeled_set():
    root = os.environ.get("OL_DATA_ROOT")
    dump_date = os.environ.get("OL_DATA_VERSION")
    if not (root and dump_date):
        pytest.skip("set OL_DATA_ROOT and OL_DATA_VERSION")

    thresholds = _thresholds()
    paths = ArtifactPaths(root=Path(root), dump_date=dump_date)
    cases = load_cases()

    # R51: with the prepared cache this costs seconds; without it, ~31
    # minutes. OL_PREPARED_CACHE overrides; otherwise fall back to the
    # conventional path used by the CLI and the build gate, if it exists.
    cache_env = os.environ.get("OL_PREPARED_CACHE")
    default_cache = paths.tmp_dir / f"prepared-{dump_date}.json"
    cache_path = (
        Path(cache_env) if cache_env else (default_cache if default_cache.exists() else None)
    )

    con = connect(paths, memory_limit="8GB")
    try:
        prepared = read_prepared_cache(cache_path, dump_date, len(cases)) if cache_path else None
        if prepared is not None:
            metrics, _ = evaluate(prepared, load_weights())
        else:
            metrics, _ = run(con, paths, cases, load_weights())
    finally:
        con.close()

    assert metrics.candidate_recall[10] >= thresholds["min_candidate_recall_10"]
    assert metrics.false_merge_rate <= thresholds["max_false_merge_rate"]
    assert metrics.precision_at_accept >= thresholds["min_precision_at_accept"]
    assert metrics.abstention_rate <= thresholds["max_abstention_rate"]
    assert metrics.correct_no_match_rate >= thresholds["min_correct_no_match_rate"]
    assert metrics.false_reject_rate <= thresholds["max_false_reject_rate"]
