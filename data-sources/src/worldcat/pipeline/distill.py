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
    _require_known_passes(con, paths)
    target = paths.table("records")
    con.execute(
        f"""
        COPY (
          WITH {_pass_rank_cte()},
          src AS (
            SELECT s.*, pr.pass_rank,
                   CASE s.type WHEN 'title_json' THEN 0 ELSE 1 END AS type_rank
            FROM read_parquet('{shards_glob(paths)}') s JOIN pr USING (pass)
            WHERE s.kind = 'record'
          ),
          ranked AS (
            SELECT *, row_number() OVER (
              PARTITION BY oclc ORDER BY pass_rank, type_rank, pass_index DESC NULLS LAST
            ) AS rn
            FROM src
          ),
          isbn_union AS (
            SELECT oclc,
                   list_distinct(list_filter(
                     list_transform(flatten(list(isbns_raw)), x -> {isbn13_sql("x")}),
                     x -> x IS NOT NULL)) AS isbn13s
            FROM src GROUP BY oclc
          )
          SELECT r.oclc, r.title, r.subtitle, r.creator, r.contributors, r.year,
                 r.publication_date_raw, r.publisher, r.publication_place,
                 r.cataloging_language, r.specific_format, r.edition_statement,
                 r.physical_description, r.series, r.genre, r.subjects,
                 u.isbn13s, r.merged_oclc, r.other_format_oclc, r.total_editions, r.summary,
                 r.type AS source_type, r.pass AS source_pass
          FROM ranked r JOIN isbn_union u USING (oclc)
          WHERE r.rn = 1
          ORDER BY r.oclc
        ) TO '{target}' (FORMAT parquet, COMPRESSION zstd, ROW_GROUP_SIZE {ROW_GROUP})
        """
    )
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
