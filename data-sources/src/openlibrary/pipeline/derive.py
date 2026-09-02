"""Derived tables: work_authors, year_evidence, popularity.

Everything here reads Parquet, not .gz. The expensive single-threaded scans all
happened in the staging step.
"""

from __future__ import annotations

import duckdb

from .paths import ArtifactPaths


def build_work_authors(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths) -> int:
    """Explode work -> author pairs.

    `unnest(..., ...)` with the list already filtered by DuckDB's JSON wildcard
    means entries with no `author` key never reach here; positions are numbered
    over the survivors, densely, so a malformed entry cannot leave a hole.
    """
    staged = paths.staging("works_raw")
    con.execute(
        f"""
        COPY (
          SELECT
            work_key,
            author_key,
            CAST(position AS SMALLINT) AS position
          FROM (
            SELECT
              work_key,
              unnest(author_keys) AS author_key,
              generate_subscripts(author_keys, 1) AS position
            FROM '{staged}'
            WHERE author_keys IS NOT NULL AND len(author_keys) > 0
          )
          WHERE author_key IS NOT NULL AND author_key <> ''
        ) TO '{paths.table("work_authors")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )
    (count,) = con.execute(f"SELECT count(*) FROM '{paths.table('work_authors')}'").fetchone()
    return count
