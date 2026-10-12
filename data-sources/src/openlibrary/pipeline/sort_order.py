"""The physical order of the tables the API looks rows up in by key.

Nothing here carries an index. A point lookup is fast only when DuckDB can
skip row groups by their min/max statistics, and that needs the file sorted by
the looked-up columns. Unsorted, `GET /identifiers` read every row group of
its identifier type (identifiers is ~120M rows) and probed all of `works`:
about 1.1 CPU-seconds a lookup against 27 ms sorted, measured on the
2026-07-31 artifact. During the 2026-10 Goodreads replay those lookups held the
home server's ol VM at 100% CPU.

Order is physical only: no query depends on it, and sorting changes no
answer, so it needs no PIPELINE_VERSION bump. An artifact built before this
module is re-sorted in place by `openlibrary.pipeline.resort`.
"""

from __future__ import annotations

from pathlib import Path

import duckdb

SORT_KEYS: dict[str, tuple[str, ...]] = {
    "identifiers": ("id_type", "value"),
    "works": ("work_key",),
    "redirects": ("entity", "source_key"),
}


def order_by(table: str) -> str:
    return ", ".join(SORT_KEYS[table])


def row_groups_in_order(con: duckdb.DuckDBPyConnection, path: Path, keys: tuple[str, ...]) -> bool:
    """Whether consecutive row groups are in `keys` order, read from the
    Parquet footer alone (no data pages), so it is cheap enough to check a
    120M-row file before swapping it into a served version.

    Row group A may precede B when A's max is below B's min on the first key.
    On a tie the next key decides, but only when the tied key is constant in
    both groups: otherwise the later keys' statistics mix rows from different
    first-key values and say nothing about order. That is a weaker check than
    reading every row, and enough to tell a sorted file from one written
    without an ORDER BY, whose row groups overlap on every key."""
    rows = con.execute(
        "SELECT row_group_id, path_in_schema, stats_min_value, stats_max_value "
        "FROM parquet_metadata(?) WHERE path_in_schema IN (SELECT unnest(?))",
        [str(path), list(keys)],
    ).fetchall()
    groups: dict[int, dict[str, tuple[str, str]]] = {}
    for group, column, low, high in rows:
        groups.setdefault(group, {})[column] = (low, high)
    ordered = [groups[g] for g in sorted(groups)]
    for before, after in zip(ordered, ordered[1:], strict=False):
        for key in keys:
            (_, before_max), (after_min, _) = before[key], after[key]
            if before_max < after_min:
                break
            if before_max > after_min:
                return False
            if not (before[key][0] == before_max == after_min == after[key][1]):
                break
    return True
