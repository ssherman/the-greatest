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


def build_year_evidence(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths) -> int:
    """Year CANDIDATES per work. There is deliberately no answer column.

    89% of works carry no publication date, so the edition years are usually the
    only signal -- and one malformed edition must not be able to move a
    19th-century book. `second_min_edition_year` is what makes a lone early
    outlier visible instead of authoritative.
    """
    con.execute(
        f"""
        COPY (
          WITH edition_years AS (
            SELECT work_key, publish_year
            FROM '{paths.table("editions")}'
            WHERE work_key IS NOT NULL
          ),
          per_work AS (
            SELECT
              work_key,
              count(*)                                          AS edition_count,
              count(publish_year)                               AS edition_year_count,
              min(publish_year)                                 AS min_edition_year,
              CAST(
                list_sort(
                  list_distinct(list(publish_year) FILTER (WHERE publish_year IS NOT NULL))
                )[2]
                AS INTEGER
              )                                                 AS second_min_edition_year,
              mode(publish_year)                                AS modal_edition_year
            FROM edition_years
            GROUP BY work_key
          ),
          with_modal_count AS (
            SELECT
              p.*,
              CAST((
                SELECT count(*) FROM edition_years e
                WHERE e.work_key = p.work_key AND e.publish_year = p.modal_edition_year
              ) AS INTEGER) AS modal_edition_year_count
            FROM per_work p
          )
          SELECT
            w.work_key,
            d.declared_year,
            COALESCE(m.min_edition_year, NULL)                  AS min_edition_year,
            m.second_min_edition_year,
            m.modal_edition_year,
            COALESCE(m.modal_edition_year_count, 0)             AS modal_edition_year_count,
            COALESCE(m.edition_year_count, 0)                   AS edition_year_count,
            COALESCE(m.edition_count, 0)                        AS edition_count
          FROM '{paths.table("works")}' w
          LEFT JOIN '{paths.table("work_details")}' d USING (work_key)
          LEFT JOIN with_modal_count m USING (work_key)
          WHERE d.declared_year IS NOT NULL OR m.edition_count IS NOT NULL
        ) TO '{paths.table("year_evidence")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )
    (count,) = con.execute(f"SELECT count(*) FROM '{paths.table('year_evidence')}'").fetchone()
    return count
