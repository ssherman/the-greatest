"""editions dump -> editions.parquet + identifiers.parquet.

The expensive pass: 12.5 GB compressed, single-threaded, ~5-10 minutes. One scan
into staging, both tables derived from it. Getting the column list wrong here
costs a re-read of 12.5 GB, which is why OCLC, LCCN and Goodreads are extracted
even though nothing consumes them yet.

`identifiers` has no uniqueness on `value` on purpose: ISBNs are reused, and a
caller is meant to see several works for one identifier rather than have the
ambiguity hidden.
"""

from __future__ import annotations

import datetime

import duckdb

from common.normalize import (
    asin_sql,
    goodreads_sql,
    isbn10_sql,
    isbn13_sql,
    isbn_checksum_ok_sql,
    lccn_sql,
    oclc_sql,
)

from .paths import ArtifactPaths
from .works import read_dump_sql

# The printing press. A 4-digit run below this in a publish_date is a catalogue
# artefact, not a year. 0.17% of publish_date values are MARC filler ("19uu",
# "17--") that yields no year at all.
MIN_EDITION_YEAR = 1450
MAX_EDITION_YEAR_OFFSET = 1


def _publish_year_sql(expr: str) -> str:
    max_year = datetime.date.today().year + MAX_EDITION_YEAR_OFFSET
    extracted = f"TRY_CAST(regexp_extract({expr}, '(\\d{{4}})', 1) AS INTEGER)"
    return (
        f"CASE WHEN {extracted} BETWEEN {MIN_EDITION_YEAR} AND {max_year} "
        f"THEN {extracted} ELSE NULL END"
    )


def stage_editions(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths) -> int:
    source = read_dump_sql(paths.dump("editions"))
    target = paths.staging("editions_raw")
    con.execute(
        f"""
        COPY (
          SELECT
            replace(column1, '/books/', '')                          AS edition_key,
            list_transform(
              json_extract_string(column4, '$.works[*].key'),
              x -> replace(x, '/works/', '')
            )                                                        AS work_keys,
            json_extract_string(column4, '$.title')                  AS title,
            json_extract_string(column4, '$.subtitle')               AS subtitle,
            json_extract_string(column4, '$.publish_date')           AS publish_date_raw,
            list_transform(
              json_extract_string(column4, '$.languages[*].key'),
              x -> replace(x, '/languages/', '')
            )                                                        AS language_codes,
            TRY_CAST(json_extract_string(column4, '$.number_of_pages') AS INTEGER)
                                                                     AS page_count,
            json_extract_string(column4, '$.publishers[0]')          AS publisher,
            json_extract_string(column4, '$.physical_format')        AS physical_format,
            json_extract_string(column4, '$.edition_name')           AS edition_name,
            json_extract_string(column4, '$.series[*]')              AS series,
            json_extract_string(column4, '$.isbn_13[*]')             AS isbn_13_raw,
            json_extract_string(column4, '$.isbn_10[*]')             AS isbn_10_raw,
            json_extract_string(column4, '$.oclc_numbers[*]')        AS oclc_raw,
            json_extract_string(column4, '$.lccn[*]')                AS lccn_raw,
            json_extract_string(column4, '$.identifiers.amazon[*]')  AS asin_raw,
            json_extract_string(column4, '$.identifiers.goodreads[*]') AS goodreads_raw,
            json_extract_string(column4, '$.source_records[*]')      AS source_records,
            TRY_CAST(column2 AS INTEGER)                             AS revision,
            TRY_CAST(column3 AS DATE)                                AS last_modified
          FROM {source}
          WHERE column0 = '/type/edition'
        ) TO '{target}' (FORMAT parquet, COMPRESSION zstd);
        """
    )
    (count,) = con.execute(f"SELECT count(*) FROM '{target}'").fetchone()
    return count


def build_editions(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths) -> dict[str, int]:
    staged = paths.staging("editions_raw")

    con.execute(
        f"""
        COPY (
          SELECT
            edition_key,
            CASE WHEN work_keys IS NULL OR len(work_keys) = 0 THEN NULL
                 ELSE work_keys[1] END                    AS work_key,
            title,
            subtitle,
            {_publish_year_sql("publish_date_raw")}       AS publish_year,
            publish_date_raw,
            CASE WHEN language_codes IS NULL OR len(language_codes) = 0 THEN NULL
                 ELSE language_codes[1] END               AS language_code,
            page_count,
            publisher,
            physical_format,
            edition_name,
            series,
            revision,
            last_modified
          FROM '{staged}'
        ) TO '{paths.table("editions")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )

    # Each identifier family becomes its own SELECT over the exploded raw list,
    # then the whole thing is UNIONed. ASINs arrive two ways: from
    # `identifiers.amazon` and from `source_records` entries prefixed "amazon:".
    con.execute(
        f"""
        COPY (
          WITH base AS (
            SELECT
              edition_key,
              CASE WHEN work_keys IS NULL OR len(work_keys) = 0 THEN NULL
                   ELSE work_keys[1] END AS work_key,
              isbn_13_raw, isbn_10_raw, oclc_raw, lccn_raw, asin_raw,
              goodreads_raw, source_records
            FROM '{staged}'
          ),
          isbn_any AS (
            SELECT edition_key, work_key, unnest(isbn_13_raw) AS raw FROM base
              WHERE isbn_13_raw IS NOT NULL AND len(isbn_13_raw) > 0
            UNION ALL
            SELECT edition_key, work_key, unnest(isbn_10_raw) AS raw FROM base
              WHERE isbn_10_raw IS NOT NULL AND len(isbn_10_raw) > 0
          ),
          source_record_asins AS (
            SELECT edition_key, work_key, unnest(source_records) AS record
            FROM base WHERE source_records IS NOT NULL AND len(source_records) > 0
          )
          SELECT 'isbn13' AS id_type, {isbn13_sql("raw")} AS value, edition_key, work_key,
                 {isbn_checksum_ok_sql("raw")} AS checksum_ok
          FROM isbn_any WHERE {isbn13_sql("raw")} IS NOT NULL

          UNION ALL
          SELECT 'isbn10', {isbn10_sql("raw")}, edition_key, work_key,
                 {isbn_checksum_ok_sql("raw")}
          FROM isbn_any WHERE {isbn10_sql("raw")} IS NOT NULL

          UNION ALL
          SELECT 'oclc', {oclc_sql("raw")}, edition_key, work_key, NULL
          FROM (SELECT edition_key, work_key, unnest(oclc_raw) AS raw FROM base
                WHERE oclc_raw IS NOT NULL AND len(oclc_raw) > 0)
          WHERE {oclc_sql("raw")} IS NOT NULL

          UNION ALL
          SELECT 'lccn', {lccn_sql("raw")}, edition_key, work_key, NULL
          FROM (SELECT edition_key, work_key, unnest(lccn_raw) AS raw FROM base
                WHERE lccn_raw IS NOT NULL AND len(lccn_raw) > 0)
          WHERE {lccn_sql("raw")} IS NOT NULL

          UNION ALL
          SELECT 'asin', {asin_sql("raw")}, edition_key, work_key, NULL
          FROM (
            SELECT edition_key, work_key, unnest(asin_raw) AS raw FROM base
              WHERE asin_raw IS NOT NULL AND len(asin_raw) > 0
            UNION ALL
            SELECT edition_key, work_key,
                   regexp_extract(record, '^amazon:(.+)$', 1) AS raw
            FROM source_record_asins
          )
          WHERE {asin_sql("raw")} IS NOT NULL

          UNION ALL
          -- [GOODREADS]
          SELECT 'goodreads', {goodreads_sql("raw")}, edition_key, work_key, NULL
          FROM (SELECT edition_key, work_key, unnest(goodreads_raw) AS raw FROM base
                WHERE goodreads_raw IS NOT NULL AND len(goodreads_raw) > 0)
          WHERE {goodreads_sql("raw")} IS NOT NULL
        ) TO '{paths.table("identifiers")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )

    (editions_n,) = con.execute(f"SELECT count(*) FROM '{paths.table('editions')}'").fetchone()
    (identifiers_n,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('identifiers')}'"
    ).fetchone()
    (no_work,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('editions')}' WHERE work_key IS NULL"
    ).fetchone()
    return {
        "editions": editions_n,
        "identifiers": identifiers_n,
        "editions_without_work": no_work,
    }
