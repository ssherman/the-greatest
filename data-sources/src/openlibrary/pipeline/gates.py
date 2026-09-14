"""The Open Library gate set. A failing gate means the build is not promoted.

Four families, from the design:
  * row counts and field coverage within tolerance of the previous build
  * redirect closure: every chain terminates, no cycles beyond what was expected
  * canary lookups: a fixed list of known works still resolves
  * the evaluation set does not regress against the pinned thresholds (Task 28)
"""

from __future__ import annotations

import json
import time
from pathlib import Path
from typing import TYPE_CHECKING

import duckdb

from common.gates import GateResult, within_tolerance

from .paths import TABLES, ArtifactPaths

if TYPE_CHECKING:
    # Type-only: keeps the pipeline -> eval dependency lazy at import time
    # (see evaluation_gate's docstring) while still letting `threshold_failures`
    # carry a real annotation.
    from openlibrary.eval.harness import Metrics

# Chosen because they are the four documented shared-key collisions: an omnibus,
# a two-language work, a wrong-data pairing, and a real duplicate. If any stops
# resolving, the failure is structural rather than statistical.
CANARY_WORK_KEYS = (
    "OL3809593W",
    "OL2014226W",
    "OL81205W",
    "OL8331643W",
)

MAX_ROW_DROP = 0.05
MAX_ROW_RISE = 0.50
MAX_COVERAGE_DROP = 0.10


def run_gates(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    *,
    previous_report: dict | None,
) -> list[GateResult]:
    results: list[GateResult] = []
    previous_tables = (previous_report or {}).get("tables", {})

    # 1. Row counts
    observed: dict[str, int] = {}
    offenders: list[str] = []
    for table in TABLES:
        path = paths.table(table)
        if not path.exists():
            offenders.append(f"{table}: missing")
            continue
        (rows,) = con.execute(f"SELECT count(*) FROM '{path}'").fetchone()
        observed[table] = rows
        previous_rows = previous_tables.get(table, {}).get("rows")
        if not within_tolerance(previous_rows, rows, max_drop=MAX_ROW_DROP, max_rise=MAX_ROW_RISE):
            offenders.append(f"{table}: {previous_rows:,} -> {rows:,}")
    results.append(
        GateResult(
            name="row_counts",
            status="fail" if offenders else "pass",
            detail="; ".join(offenders) or "all tables within tolerance",
            observed=observed,
        )
    )

    # 2. Field coverage on the columns each table's usefulness actually depends on
    coverage: dict[str, float] = {}
    coverage_offenders: list[str] = []
    checks = (
        ("works.title_fp_nonempty", paths.table("works"), "title_fp <> ''"),
        ("works.has_authors", paths.table("works"), "author_count > 0"),
        ("editions.has_work", paths.table("editions"), "work_key IS NOT NULL"),
        ("editions.has_year", paths.table("editions"), "publish_year IS NOT NULL"),
    )
    for name, path, predicate in checks:
        row = con.execute(
            f"SELECT count(*) FILTER (WHERE {predicate}), count(*) FROM '{path}'"
        ).fetchone()
        ratio = (row[0] / row[1]) if row[1] else 0.0
        coverage[name] = ratio
        previous_ratio = (previous_report or {}).get("coverage", {}).get(name)
        if not within_tolerance(previous_ratio, ratio, max_drop=MAX_COVERAGE_DROP, max_rise=1.0):
            coverage_offenders.append(f"{name}: {previous_ratio} -> {ratio:.4f}")
    results.append(
        GateResult(
            name="field_coverage",
            status="fail" if coverage_offenders else "pass",
            detail="; ".join(coverage_offenders) or "coverage within tolerance",
            observed=coverage,
        )
    )

    # 3. Redirect closure
    row = con.execute(
        f"""
        SELECT
          count(*) FILTER (WHERE NOT is_cycle
            AND terminal_key IN (SELECT source_key FROM '{paths.table("redirects")}')),
          count(*) FILTER (WHERE is_cycle),
          count(*) FILTER (WHERE is_dangling),
          count(*)
        FROM '{paths.table("redirects")}'
        """
    ).fetchone()
    unclosed, cycles, dangling, total = row
    results.append(
        GateResult(
            name="redirect_closure",
            status="fail" if unclosed else "pass",
            detail=(
                f"{unclosed:,} chains did not terminate"
                if unclosed
                else f"{total:,} redirects, {cycles:,} cycles, {dangling:,} dangling"
            ),
            observed={
                "unclosed": unclosed,
                "cycles": cycles,
                "dangling": dangling,
                "total": total,
            },
        )
    )

    # 4. Canary lookups
    missing = []
    for key in CANARY_WORK_KEYS:
        (found,) = con.execute(
            f"SELECT count(*) FROM '{paths.table('works')}' WHERE work_key = ?", [key]
        ).fetchone()
        if not found:
            missing.append(key)
    results.append(
        GateResult(
            name="canary_lookups",
            status="fail" if missing else "pass",
            detail=f"missing: {missing}" if missing else "all canaries resolve",
            observed={"missing": missing},
        )
    )

    # 5. Evaluation set -- see evaluation_gate's docstring.
    results.append(evaluation_gate(con, paths))

    return results


def gates_passed(results: list[GateResult]) -> bool:
    return all(result.status != "fail" for result in results)


def threshold_failures(metrics: Metrics, thresholds: dict) -> list[str]:
    """Every metric that misses its pinned bound in `thresholds`. Empty means
    no regression.

    A pure function on purpose: the pass/fail logic can be exercised with a
    hand-built `Metrics` and a hand-built thresholds dict, with no built
    artifact, no labeled set, and no matcher import required beyond this one
    (deliberately lazy, matching `evaluation_gate`'s docstring).

    Iterates `harness.THRESHOLD_CHECKS` -- the SAME table
    `tests/openlibrary/test_eval_regression.py` iterates for the artifact
    regression assertions and the "every threshold has a measured sibling"
    check (R56), so a threshold added to `thresholds.json` without a matching
    entry there, or here, fails a test rather than silently going unchecked
    on one side.
    """
    from openlibrary.eval.harness import THRESHOLD_CHECKS, threshold_value

    failures = []
    for label, direction, attribute, key in THRESHOLD_CHECKS:
        bound = thresholds[key]
        value = threshold_value(metrics, attribute)
        if direction == "min" and value < bound:
            failures.append(f"{label} {value:.4f} < {bound:.4f}")
        elif direction == "max" and value > bound:
            failures.append(f"{label} {value:.4f} > {bound:.4f}")
    return failures


def evaluation_gate(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    prepared_cache: Path | None = None,
) -> GateResult:
    """The labeled set does not regress against the pinned thresholds
    (`eval/thresholds.json`, Task 28).

    Skips, rather than failing, whenever the check would not mean anything:
    no labeled cases, no pinned thresholds yet, or -- R50 -- an artifact whose
    labeled works are mostly absent from it. That last case is what keeps this
    gate honest against the fixture corpus, which is built from a handful of
    real works and does not contain the 370 works the labeled set's `match`
    cases name, without also skipping a future real dump that is merely
    missing a handful of keys to normal Open Library churn.

    Costs ~4.5s/case with no prepared cache available (~31 minutes for the
    full 448-case set), and seconds when one is (R51/R54): `prepared_cache`
    defaults to the conventional path under `paths.tmp_dir` if a file already
    sits there, and is read but never written here -- this gate is read-only
    on the artifact's scratch space. `run_gates` always calls this with the
    default (no explicit cache path).
    """
    try:
        from openlibrary.eval.dataset import load_cases, unknown_labeled_keys
        from openlibrary.eval.harness import THRESHOLDS_PATH, evaluate, prepare, read_prepared_cache
        from openlibrary.matcher.scorer import load_weights
    except ImportError as error:
        return GateResult("evaluation_set", "skipped", f"matcher not importable: {error}")

    cases = load_cases()
    if not cases:
        return GateResult("evaluation_set", "skipped", "no labeled evaluation set")

    n_labeled = sum(1 for case in cases if case.label.work_key)
    if n_labeled:
        n_unknown = len(unknown_labeled_keys(con, paths, cases))
        if n_unknown * 2 > n_labeled:
            return GateResult(
                "evaluation_set",
                "skipped",
                f"labelled works absent from this artifact ({n_unknown} of {n_labeled}); "
                "not the labelled dump",
                observed={"n_unknown": n_unknown, "n_labeled": n_labeled},
            )

    if not THRESHOLDS_PATH.exists():
        return GateResult("evaluation_set", "skipped", "no pinned thresholds")
    thresholds = json.loads(THRESHOLDS_PATH.read_text())

    if prepared_cache is None:
        default_cache = paths.tmp_dir / f"prepared-{paths.dump_date}.json"
        prepared_cache = default_cache if default_cache.exists() else None

    started = time.monotonic()
    prepared = (
        read_prepared_cache(prepared_cache, paths.dump_date, len(cases)) if prepared_cache else None
    )
    from_cache = prepared is not None
    if prepared is None:
        prepared = prepare(con, paths, cases)
    metrics, _ = evaluate(prepared, load_weights())
    elapsed = time.monotonic() - started

    failures = threshold_failures(metrics, thresholds)
    timing = f"{'prepared cache' if from_cache else 'prepared fresh'}, {elapsed:.1f}s"
    detail = f"{'; '.join(failures) if failures else 'no regression on the labeled set'} ({timing})"
    return GateResult(
        name="evaluation_set",
        status="fail" if failures else "pass",
        detail=detail,
        observed={**metrics.model_dump(), "thresholds": thresholds},
    )
