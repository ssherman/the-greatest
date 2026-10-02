"""The labeled set as a regression suite (Task 28).

The service is a pure function of `(request, source_version)`, so once the
matcher and the labeled set both exist, a change in the matcher's answers is
either a code change or a data change -- and these thresholds are what makes
that difference visible. They are pinned from the measured numbers of the
final calibration run (`thresholds.json`'s `measured` block), with headroom
in the safe direction, never from ambition.

Every assertion here iterates `harness.THRESHOLD_CHECKS` -- the same table
`pipeline.gates.threshold_failures` (the build gate) iterates -- rather than
naming the six metrics a second time (R56): a threshold added to
`thresholds.json` without a matching entry in `THRESHOLD_CHECKS`, or the
other way around, fails `test_threshold_checks_names_exactly_the_pinned_thresholds`
below instead of silently going unchecked on one side.
"""

from __future__ import annotations

import json
import os
from pathlib import Path

import pytest

from openlibrary.eval.dataset import load_cases
from openlibrary.eval.harness import (
    THRESHOLD_CHECKS,
    THRESHOLDS_PATH,
    evaluate,
    read_prepared_cache,
    run,
    threshold_value,
)
from openlibrary.matcher.scorer import MATCHER_VERSION, load_weights
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths

# Everything in thresholds.json that is provenance, not a pinned bound.
_METADATA_KEYS = {
    "measured_at",
    "dump_date",
    "matcher_version",
    "n_cases",
    "weights_calibrated_at",
    "source",
    "measured",
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


def test_threshold_checks_names_exactly_the_pinned_thresholds():
    """A threshold added to thresholds.json without a matching THRESHOLD_CHECKS
    entry (or vice versa) must fail here, not go unchecked on one side."""
    data = _thresholds()
    pinned_keys = set(data) - _METADATA_KEYS
    checks_keys = {key for _, _, _, key in THRESHOLD_CHECKS}
    assert checks_keys == pinned_keys
    assert checks_keys == set(data["measured"])


def test_every_threshold_has_a_measured_sibling_within_its_headroom():
    """The "measured, not aspirational" invariant, checked in code: each pinned
    bound must sit on the safe side of the value it was measured from -- a
    minimum at or below what was measured, a maximum at or above it."""
    data = _thresholds()
    measured = data["measured"]
    for _, direction, _, key in THRESHOLD_CHECKS:
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
    # conventional path the CLIs write, if it exists. (The build gate itself
    # never does this -- R60 -- but a test may: `read_prepared_cache` still
    # refuses the file unless its artifact timestamp and code fingerprint
    # match the artifact and code under test.)
    cache_env = os.environ.get("OL_PREPARED_CACHE")
    default_cache = paths.tmp_dir / f"prepared-{dump_date}.json"
    cache_path = (
        Path(cache_env) if cache_env else (default_cache if default_cache.exists() else None)
    )

    con = connect(paths, memory_limit="8GB")
    try:
        prepared = read_prepared_cache(cache_path, paths, len(cases)) if cache_path else None
        if prepared is not None:
            metrics, _ = evaluate(prepared, load_weights())
        else:
            metrics, _ = run(con, paths, cases, load_weights())
    finally:
        con.close()

    for label, direction, attribute, key in THRESHOLD_CHECKS:
        bound = thresholds[key]
        value = threshold_value(metrics, attribute)
        if direction == "min":
            assert value >= bound, f"{label}: {value:.4f} < {bound:.4f}"
        else:
            assert value <= bound, f"{label}: {value:.4f} > {bound:.4f}"
