"""The Open Library gate set. A failing gate means the build is not promoted.

Four families, from the design:
  * row counts and field coverage within tolerance of the previous build
  * redirect closure: every chain terminates, no cycles beyond what was expected
  * canary lookups: a fixed list of known works still resolves
  * the evaluation set does not regress   <- wired in Increment 3
"""

from __future__ import annotations

import duckdb

from common.gates import GateResult, within_tolerance

from .paths import TABLES, ArtifactPaths

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

    # 5. Evaluation set -- the contract exists now, the check arrives in Increment 3.
    results.append(
        GateResult(
            name="evaluation_set",
            status="skipped",
            detail="no labeled evaluation set yet (Increment 2)",
            observed={},
        )
    )

    return results


def gates_passed(results: list[GateResult]) -> bool:
    return all(result.status != "fail" for result in results)
