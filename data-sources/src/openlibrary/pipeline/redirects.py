"""redirects dump -> redirects.parquet, transitively resolved.

Three outcomes, all representable:
  resolved  -- terminates at a key that exists in the corpus
  dangling  -- terminates at a key that does not exist (OL deleted it)
  cycle     -- revisits a key; terminal_key is NULL

A depth cap makes the iteration terminate regardless of the data; anything still
moving at the cap is treated as a cycle. 9.9% of our stored OL work keys are
dead, so this table is the difference between a resolution and a 404.

`location` is usually a full path ("/authors/OL1319517A") but 6,987 of the
1,790,272 records in the 2026-07-31 dump store it as a bare key
("OL2538914A") instead -- an old-revision quirk in the upstream data, not
ours. Open Library's key suffix (A/W/M) already disambiguates entity type and
a redirect never crosses entity kinds, so a bare target is normalized against
its own source's entity. Left bare, a cursor built from it can never match
`redirect_edges.source_path` (always the full `$.key`) in the loop below, so a
chain silently stops one hop short whenever that bare target is itself a
further redirect -- confirmed against the real dump: exactly one chain
(OL6022750A -> OL2538914A -> /authors/OL1319517A) did.
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
        WITH raw AS (
          SELECT
            CASE
              WHEN starts_with(json_extract_string(column4, '$.key'), '/works/')   THEN 'work'
              WHEN starts_with(json_extract_string(column4, '$.key'), '/authors/') THEN 'author'
              WHEN starts_with(json_extract_string(column4, '$.key'), '/books/')   THEN 'edition'
              ELSE 'other'
            END                                                     AS entity,
            json_extract_string(column4, '$.key')                   AS source_path,
            json_extract_string(column4, '$.location')              AS location_raw
          FROM {source}
          WHERE column0 = '/type/redirect'
            AND json_extract_string(column4, '$.location') IS NOT NULL
            -- A NULL `$.key` here would carry through as a NULL source_path.
            -- The closure check below tests `cursor_path IN (SELECT
            -- source_path FROM redirect_edges)`: SQL `IN` against a column
            -- containing NULL evaluates to NULL (not false) for every row
            -- that doesn't otherwise match, so ONE such record turns
            -- `is_cycle` NULL for the entire table -- and gates.py's `NOT
            -- is_cycle` count then reports `unclosed = 0` no matter how
            -- broken the data actually is. Today's dump has no such record,
            -- but this branch already hit one differently-malformed redirect
            -- in 1,790,272 records, so this is guarded rather than assumed.
            AND json_extract_string(column4, '$.key') IS NOT NULL
        )
        SELECT
          entity,
          source_path,
          CASE
            WHEN location_raw LIKE '/%'  THEN location_raw
            WHEN entity = 'work'         THEN '/works/' || location_raw
            WHEN entity = 'author'       THEN '/authors/' || location_raw
            WHEN entity = 'edition'      THEN '/books/' || location_raw
            ELSE location_raw
          END                                                       AS target_path
        FROM raw;
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
        # `NOT s.is_cycle` has to live in a WHERE, not the ON: a predicate on the
        # left side inside a LEFT JOIN's ON clause stops DuckDB from planning
        # this as an equi-join (source_path = cursor_path) and forces a nested
        # loop instead -- O(rows^2) over 1.79M rows, measured at 2,703s. The
        # already-cyclic rows are split off and passed through unchanged
        # instead, keeping the join itself a plain hash join on equality.
        con.execute(
            f"""
            CREATE OR REPLACE TABLE {other} AS
            SELECT
              s.entity,
              s.source_path,
              COALESCE(e.target_path, s.cursor_path) AS cursor_path,
              CASE WHEN e.target_path IS NULL THEN s.depth
                   ELSE CAST(s.depth + 1 AS SMALLINT) END AS depth,
              (e.target_path IS NOT NULL AND e.target_path = s.source_path) AS is_cycle
            FROM {current} s
            LEFT JOIN redirect_edges e ON e.source_path = s.cursor_path
            WHERE NOT s.is_cycle

            UNION ALL

            SELECT entity, source_path, cursor_path, depth, is_cycle
            FROM {current}
            WHERE is_cycle;
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
            -- 'edition' and 'other' are never checked against a table below --
            -- editions.parquet does not exist yet at this point in the pipeline
            -- order, and this table is not the place to add that dependency.
            -- The ELSE arm is therefore NULL ("unknown"), not false: `false`
            -- would assert those redirects resolve when nobody looked. Measured
            -- against the built artifact, 78 of 115,947 edition redirects
            -- terminate at an edition_key absent from editions.parquet while
            -- silently carrying is_dangling = false under the old ELSE false.
            CASE
              WHEN s.is_cycle THEN false
              WHEN s.entity = 'work' THEN
                regexp_replace(s.cursor_path, '^/works/', '')
                  NOT IN (SELECT work_key FROM '{paths.table("works")}')
              WHEN s.entity = 'author' THEN
                regexp_replace(s.cursor_path, '^/authors/', '')
                  NOT IN (SELECT author_key FROM '{paths.table("authors")}')
              ELSE NULL
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
