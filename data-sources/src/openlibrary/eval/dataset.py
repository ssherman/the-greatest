"""Load the evaluation set and compare work keys across dump versions.

A label written against 2026-07-31 may name a work that 2026-08-31 has merged
away. Comparison therefore resolves BOTH sides through redirects before deciding
whether two keys are the same work -- otherwise every monthly rebuild would show
a phantom regression.
"""

from __future__ import annotations

import collections
from collections.abc import Iterable
from pathlib import Path

import duckdb

from openlibrary.eval.schema import EvalCase
from openlibrary.pipeline.paths import ArtifactPaths

CASES_DIR = Path(__file__).parent / "cases"


def load_cases(directory: Path | None = None, *, include_proposed: bool = False) -> list[EvalCase]:
    """Read every `*.jsonl` file in `directory` (default: `CASES_DIR`).

    A plain `agent` label is a proposal awaiting confirmation, not ground
    truth -- it is excluded unless `include_proposed=True`. The set's ground
    truth is human labels plus `agent_confirmed` labels only. Duplicate-id
    detection runs across every row read, proposals included, so a typo
    hiding behind an excluded proposal is still caught.
    """
    target = Path(directory) if directory else CASES_DIR
    cases: list[EvalCase] = []
    seen: set[str] = set()
    for path in sorted(target.glob("*.jsonl")):
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            case = EvalCase.model_validate_json(line)
            if case.case_id in seen:
                raise ValueError(f"duplicate case_id {case.case_id!r} in {path}")
            seen.add(case.case_id)
            if include_proposed or case.label.labeled_by != "agent":
                cases.append(case)
    return cases


def stratum_counts(cases: Iterable[EvalCase]) -> dict[str, int]:
    return dict(collections.Counter(case.stratum for case in cases))


def verdict_counts(cases: Iterable[EvalCase]) -> dict[str, int]:
    return dict(collections.Counter(case.label.verdict for case in cases))


def _load_rows(
    con: duckdb.DuckDBPyConnection,
    table: str,
    columns: list[tuple[str, str]],
    rows: list[tuple],
) -> None:
    """Replace `table` with `rows`, via CREATE TABLE + parameterized INSERT.

    Mirrors `build_pool._load_rows`: `con.register(name, list_of_dicts)` is
    rejected in this environment (DuckDB's Python replacement scan needs a
    pandas DataFrame, a DuckDBPyRelation, or pyarrow, and none is available
    here), so a parameterized `executemany` stands in for it.
    """
    col_defs = ", ".join(f"{name} {sql_type}" for name, sql_type in columns)
    con.execute(f"CREATE OR REPLACE TABLE {table} ({col_defs})")
    if rows:
        placeholders = ", ".join(["?"] * len(columns))
        con.executemany(f"INSERT INTO {table} VALUES ({placeholders})", rows)


def resolve_keys(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    keys: Iterable[str],
) -> dict[str, str]:
    """Map each key to its terminal key, or to itself when it is not redirected."""
    wanted = [k for k in dict.fromkeys(keys) if k]
    if not wanted:
        return {}
    _load_rows(con, "keys_to_resolve", [("work_key", "VARCHAR")], [(k,) for k in wanted])
    rows = con.execute(
        f"""
        SELECT k.work_key,
               COALESCE(r.terminal_key, k.work_key) AS terminal_key
        FROM keys_to_resolve k
        LEFT JOIN '{paths.table("redirects")}' r
          ON r.source_key = k.work_key AND r.entity = 'work' AND NOT r.is_cycle
        """
    ).fetchall()
    return {row[0]: row[1] for row in rows}


def same_work(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    left: str | None,
    right: str | None,
) -> bool:
    if not left or not right:
        return False
    resolved = resolve_keys(con, paths, [left, right])
    return resolved.get(left, left) == resolved.get(right, right)


def unknown_labeled_keys(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    cases: Iterable[EvalCase],
) -> list[tuple[str, str]]:
    """Labeled work keys that neither exist nor resolve. Usually a typed key."""
    labeled = [(c.case_id, c.label.work_key) for c in cases if c.label.work_key]
    if not labeled:
        return []
    resolved = resolve_keys(con, paths, [key for _, key in labeled])
    _load_rows(
        con,
        "labeled_keys",
        [("case_id", "VARCHAR"), ("work_key", "VARCHAR")],
        [(cid, resolved.get(key, key)) for cid, key in labeled],
    )
    rows = con.execute(
        f"""
        SELECT l.case_id, l.work_key FROM labeled_keys l
        WHERE l.work_key NOT IN (SELECT work_key FROM '{paths.table("works")}')
        """
    ).fetchall()
    found_bad = {row[1] for row in rows}
    return [(cid, key) for cid, key in labeled if resolved.get(key, key) in found_bad]
