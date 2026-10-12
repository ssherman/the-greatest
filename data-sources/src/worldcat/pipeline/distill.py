"""Stage 2: DuckDB SQL over the shards into the four artifact tables."""

import duckdb

from common.normalize import isbn13_sql, isbn_checksum_ok_sql
from worldcat.pipeline.paths import WorldcatPaths

# Newest scrape pass first. The prefix is the first path segment of
# `from_filenames[0]`. Anything not listed fails the build (UnknownPass): a
# rank is a claim about recency, and a guess here would silently decide which
# copy of a record is the truth.
PASS_ORDER: tuple[str, ...] = (
    "w2",
    "2023_05_v4_type123",
    "2023_04_v3",
    "t123",
    "search_editions_response",
    "range_query",
    "worldcat_2022_09_titles_1_backup_2022_10_12",
)
MAX_REDIRECT_HOPS = 10
ROW_GROUP = 100_000


class UnknownPass(RuntimeError):
    """A pass prefix the ranking list does not know."""


def shards_glob(paths: WorldcatPaths) -> str:
    return str(paths.staging_dir / "shard_*.parquet")


def _pass_rank_cte() -> str:
    values = ", ".join(f"('{name}', {rank})" for rank, name in enumerate(PASS_ORDER, start=1))
    return f"pr AS (SELECT * FROM (VALUES {values}) AS t(pass, pass_rank))"


def unknown_passes(con: duckdb.DuckDBPyConnection, paths: WorldcatPaths) -> list[str]:
    known = ", ".join(f"'{p}'" for p in PASS_ORDER)
    rows = con.execute(
        f"SELECT DISTINCT pass FROM read_parquet('{shards_glob(paths)}') "
        f"WHERE kind = 'record' AND pass NOT IN ({known}) ORDER BY pass"
    ).fetchall()
    return [r[0] for r in rows]


def _require_known_passes(con: duckdb.DuckDBPyConnection, paths: WorldcatPaths) -> None:
    unknown = unknown_passes(con, paths)
    if unknown:
        raise UnknownPass(
            f"pass prefixes not in PASS_ORDER: {unknown}; add them with their recency, then rebuild"
        )


def _count(con: duckdb.DuckDBPyConnection, target) -> int:
    (n,) = con.execute(f"SELECT count(*) FROM '{target}'").fetchone()
    return n


def build_records(con: duckdb.DuckDBPyConnection, paths: WorldcatPaths) -> int:
    """Three narrow passes instead of one window over every wide row.

    The first real build (299M record rows, 165M OCLC numbers) ran out of memory
    at 16 GB and again at 30 GB with a single row_number() window over the full
    row width. Picking the winner over the key columns only, then joining the
    wide columns back by (shard, row), keeps the big intermediates small enough
    to spill: `winners` is three integers per OCLC number and `isbn_union` is a
    short list per OCLC number.
    """
    _require_known_passes(con, paths)
    target = paths.table("records")
    glob = shards_glob(paths)
    con.execute(
        f"""
        CREATE OR REPLACE TEMP TABLE shards AS
        SELECT filename, row_number() OVER (ORDER BY filename) AS shard_id
        FROM (SELECT DISTINCT filename FROM read_parquet('{glob}', filename = true))
        """
    )
    # Newest pass, then title_json over briefrecords_json, then the highest pass_index
    # (NULL last): the same order the former row_number() window used.
    con.execute(
        f"""
        CREATE OR REPLACE TEMP TABLE winners AS
        WITH {_pass_rank_cte()}
        SELECT oclc, pick.shard_id AS shard_id, pick.row AS row
        FROM (
          SELECT s.oclc,
                 arg_min(
                   {{'shard_id': sh.shard_id, 'row': s.file_row_number}},
                   {{'pass_rank': pr.pass_rank,
                     'type_rank': CASE s.type WHEN 'title_json' THEN 0 ELSE 1 END,
                     'pass_desc': coalesce(-s.pass_index, 9223372036854775807)}}
                 ) AS pick
          FROM read_parquet('{glob}', filename = true, file_row_number = true) s
          JOIN pr USING (pass)
          JOIN shards sh USING (filename)
          WHERE s.kind = 'record'
          GROUP BY s.oclc
        )
        """
    )
    con.execute(
        f"""
        CREATE OR REPLACE TEMP TABLE isbn_union AS
        SELECT oclc, list(isbn13 ORDER BY isbn13) AS isbn13s
        FROM (
          SELECT DISTINCT oclc, {isbn13_sql("raw")} AS isbn13
          FROM (SELECT oclc, unnest(isbns_raw) AS raw
                FROM read_parquet('{glob}') WHERE kind = 'record')
        )
        WHERE isbn13 IS NOT NULL
        GROUP BY oclc
        """
    )
    con.execute(
        f"""
        COPY (
          SELECT s.oclc, s.title, s.subtitle, s.creator, s.contributors, s.year,
                 s.publication_date_raw, s.publisher, s.publication_place,
                 s.cataloging_language, s.specific_format, s.edition_statement,
                 s.physical_description, s.series, s.genre, s.subjects,
                 u.isbn13s, s.merged_oclc, s.other_format_oclc, s.total_editions, s.summary,
                 s.type AS source_type, s.pass AS source_pass
          FROM read_parquet('{glob}', filename = true, file_row_number = true) s
          JOIN shards sh USING (filename)
          JOIN winners w ON w.shard_id = sh.shard_id AND w.row = s.file_row_number
          JOIN isbn_union u ON u.oclc = s.oclc
          WHERE s.kind = 'record'
          ORDER BY s.oclc
        ) TO '{target}' (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE {ROW_GROUP})
        """
    )
    for temp in ("shards", "winners", "isbn_union"):
        con.execute(f"DROP TABLE IF EXISTS {temp}")
    return _count(con, target)


def build_isbns(con: duckdb.DuckDBPyConnection, paths: WorldcatPaths) -> int:
    target = paths.table("isbns")
    con.execute(
        f"""
        COPY (
          SELECT DISTINCT isbn13, oclc FROM (
            SELECT oclc, {isbn13_sql("raw")} AS isbn13, {isbn_checksum_ok_sql("raw")} AS ok
            FROM (SELECT oclc, unnest(isbns_raw) AS raw
                  FROM read_parquet('{shards_glob(paths)}') WHERE kind = 'record')
          )
          WHERE ok AND isbn13 IS NOT NULL AND length(isbn13) = 13
          ORDER BY isbn13, oclc
        ) TO '{target}' (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE {ROW_GROUP})
        """
    )
    return _count(con, target)


def build_redirects(con: duckdb.DuckDBPyConnection, paths: WorldcatPaths) -> int:
    target = paths.table("redirects")
    con.execute(
        f"""
        CREATE OR REPLACE TEMP TABLE r0 AS
        SELECT oclc AS from_oclc, arg_max(redirect_to, coalesce(pass_index, 0)) AS to_oclc
        FROM read_parquet('{shards_glob(paths)}')
        WHERE kind = 'redirect' AND redirect_to <> oclc
        GROUP BY oclc
        """
    )
    con.execute("CREATE OR REPLACE TEMP TABLE cur AS SELECT from_oclc, to_oclc FROM r0")
    for _ in range(MAX_REDIRECT_HOPS):
        con.execute(
            """
            CREATE OR REPLACE TEMP TABLE nxt AS
            SELECT c.from_oclc, coalesce(n.to_oclc, c.to_oclc) AS to_oclc
            FROM cur c LEFT JOIN r0 n ON n.from_oclc = c.to_oclc AND n.to_oclc <> c.from_oclc
            """
        )
        (changed,) = con.execute(
            "SELECT count(*) FROM nxt n JOIN cur c USING (from_oclc) WHERE n.to_oclc <> c.to_oclc"
        ).fetchone()
        con.execute("CREATE OR REPLACE TEMP TABLE cur AS SELECT * FROM nxt")
        if changed == 0:
            break
    con.execute(
        f"""
        COPY (
          SELECT c.from_oclc, c.to_oclc,
                 EXISTS (SELECT 1 FROM r0 WHERE r0.from_oclc = c.to_oclc) AS is_cycle
          FROM cur c ORDER BY c.from_oclc
        ) TO '{target}' (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE {ROW_GROUP})
        """
    )
    con.execute("DROP TABLE IF EXISTS r0")
    con.execute("DROP TABLE IF EXISTS cur")
    con.execute("DROP TABLE IF EXISTS nxt")
    return _count(con, target)


def build_holdings(con: duckdb.DuckDBPyConnection, paths: WorldcatPaths) -> int:
    target = paths.table("holdings")
    con.execute(
        f"""
        COPY (
          SELECT oclc,
                 arg_max(total_holding_count, coalesce(pass_index, 0)) AS total_holding_count,
                 arg_max(holdings_total_editions, coalesce(pass_index, 0)) AS total_editions
          FROM read_parquet('{shards_glob(paths)}')
          WHERE kind = 'holdings'
          GROUP BY oclc ORDER BY oclc
        ) TO '{target}' (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE {ROW_GROUP})
        """
    )
    return _count(con, target)
