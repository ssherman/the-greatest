"""redirects dump -> redirects.parquet, transitively resolved.

Three outcomes, all representable:
  resolved  -- terminates at a key that exists in the corpus
  dangling  -- terminates at a key that does not exist (OL deleted it)
  cycle     -- revisits a key; terminal_key is NULL

A depth cap makes the iteration terminate regardless of the data; anything still
moving at the cap is treated as a cycle. 9.9% of our stored OL work keys are
dead, so this table is the difference between a resolution and a 404.
"""

from __future__ import annotations

import duckdb

from .paths import ArtifactPaths
from .works import read_dump_sql

MAX_REDIRECT_DEPTH = 25


def build_redirects(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths) -> dict[str, int]:
    source = read_dump_sql(paths.dump("redirects"))

    con.execute(
        f"""
        CREATE OR REPLACE TABLE redirect_edges AS
        SELECT
          CASE
            WHEN starts_with(json_extract_string(column4, '$.key'), '/works/')   THEN 'work'
            WHEN starts_with(json_extract_string(column4, '$.key'), '/authors/') THEN 'author'
            WHEN starts_with(json_extract_string(column4, '$.key'), '/books/')   THEN 'edition'
            ELSE 'other'
          END                                                     AS entity,
          json_extract_string(column4, '$.key')                   AS source_path,
          json_extract_string(column4, '$.location')              AS target_path
        FROM {source}
        WHERE column0 = '/type/redirect'
          AND json_extract_string(column4, '$.location') IS NOT NULL;
        """
    )

    # Iterative closure. Each round follows one more hop for the rows that are
    # still pointing at something that is itself a redirect.
    # Ping-pong between two table names. DuckDB will not CREATE OR REPLACE a
    # table from a SELECT that reads the same table, so each round writes into
    # the other name and the pair swaps.
    con.execute(
        """
        CREATE OR REPLACE TABLE redirect_state_a AS
        SELECT entity, source_path, target_path AS cursor_path,
               CAST(1 AS SMALLINT) AS depth, false AS is_cycle
        FROM redirect_edges;
        """
    )
    current, other = "redirect_state_a", "redirect_state_b"
    for _ in range(MAX_REDIRECT_DEPTH - 1):
        (moving,) = con.execute(
            f"""
            SELECT count(*) FROM {current} s
            JOIN redirect_edges e ON e.source_path = s.cursor_path
            WHERE NOT s.is_cycle
            """
        ).fetchone()
        if moving == 0:
            break
        con.execute(
            f"""
            CREATE OR REPLACE TABLE {other} AS
            SELECT
              s.entity,
              s.source_path,
              COALESCE(e.target_path, s.cursor_path) AS cursor_path,
              CASE WHEN e.target_path IS NULL THEN s.depth
                   ELSE CAST(s.depth + 1 AS SMALLINT) END AS depth,
              s.is_cycle OR (e.target_path IS NOT NULL AND e.target_path = s.source_path)
                AS is_cycle
            FROM {current} s
            LEFT JOIN redirect_edges e
              ON e.source_path = s.cursor_path AND NOT s.is_cycle;
            """
        )
        current, other = other, current

    # Anything still pointing at a redirect after the cap is a cycle by
    # definition of the cap, whether or not we saw it revisit its own source.
    con.execute(
        f"""
        CREATE OR REPLACE TABLE {other} AS
        SELECT
          entity, source_path, cursor_path, depth,
          is_cycle OR cursor_path IN (SELECT source_path FROM redirect_edges) AS is_cycle
        FROM {current};
        """
    )
    current = other

    con.execute(
        f"""
        COPY (
          SELECT
            s.entity,
            regexp_replace(s.source_path, '^/(works|authors|books)/', '')   AS source_key,
            CASE WHEN s.is_cycle THEN NULL
                 ELSE regexp_replace(s.cursor_path, '^/(works|authors|books)/', '')
            END                                                             AS terminal_key,
            s.depth,
            s.is_cycle,
            CASE
              WHEN s.is_cycle THEN false
              WHEN s.entity = 'work' THEN
                regexp_replace(s.cursor_path, '^/works/', '')
                  NOT IN (SELECT work_key FROM '{paths.table("works")}')
              WHEN s.entity = 'author' THEN
                regexp_replace(s.cursor_path, '^/authors/', '')
                  NOT IN (SELECT author_key FROM '{paths.table("authors")}')
              ELSE false
            END                                                             AS is_dangling
          FROM {current} s
        ) TO '{paths.table("redirects")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )

    row = con.execute(
        f"""
        SELECT count(*), count(*) FILTER (WHERE is_cycle),
               count(*) FILTER (WHERE is_dangling), COALESCE(max(depth), 0)
        FROM '{paths.table("redirects")}'
        """
    ).fetchone()
    return {
        "redirects": row[0],
        "cycles": row[1],
        "dangling": row[2],
        "max_depth": row[3],
    }
