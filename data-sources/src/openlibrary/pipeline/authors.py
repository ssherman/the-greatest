"""authors dump -> authors.parquet + author_names.parquet.

Same two-stage shape as `works`: Stage A reads the .gz once into
`_staging/authors_raw.parquet`, Stage B derives the final tables from that
Parquet. `author_names` explodes each author's primary `name` plus every one
of their `alternate_names` into one row per name -- that is what turns author
resolution into a join rather than a search, and what makes pseudonyms
reachable at all.

`alternate_names` is extracted with the `$.alternate_names[*]` wildcard path,
not the plain `$.alternate_names`: `json_extract_string` only returns a
genuine `VARCHAR[]` for a wildcard path (confirmed via DESCRIBE against the
staged Parquet; see the task report). A plain path returns the serialized
JSON array as one VARCHAR, and `unnest` on that would explode characters, not
names.

Birth and death dates are free text -- "1899", "24 July 1899", "ca. 1900",
"1899-1961". `_year_sql` takes the first run of exactly four consecutive
digits and keeps it only if it falls in a plausible human-lifetime range;
anything else becomes NULL. Requiring four consecutive digits (not `\\d{1,4}`)
is deliberate: it is what stops "24 July 1899" yielding 24.
"""

from __future__ import annotations

import duckdb

from common.normalize import fingerprint_sql

from .paths import ArtifactPaths
from .works import read_dump_sql

# A 4-digit run outside this range is not a birth or death year; it is a
# catalogue number or a typo. Dropping it beats storing a wrong year.
MIN_PERSON_YEAR = 1
MAX_PERSON_YEAR = 2100


def _year_sql(expr: str) -> str:
    extracted = f"TRY_CAST(regexp_extract({expr}, '(\\d{{4}})', 1) AS INTEGER)"
    return (
        f"CASE WHEN {extracted} BETWEEN {MIN_PERSON_YEAR} AND {MAX_PERSON_YEAR} "
        f"THEN {extracted} ELSE NULL END"
    )


def stage_authors(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths) -> int:
    source = read_dump_sql(paths.dump("authors"))
    target = paths.staging("authors_raw")
    con.execute(
        f"""
        COPY (
          SELECT
            replace(column1, '/authors/', '')                        AS author_key,
            json_extract_string(column4, '$.name')                   AS name,
            json_extract_string(column4, '$.alternate_names[*]')     AS alternate_names,
            json_extract_string(column4, '$.birth_date')             AS birth_date_raw,
            json_extract_string(column4, '$.death_date')             AS death_date_raw,
            TRY_CAST(column2 AS INTEGER)                             AS revision,
            TRY_CAST(column3 AS DATE)                                AS last_modified
          FROM {source}
          WHERE column0 = '/type/author'
        ) TO '{target}' (FORMAT parquet, COMPRESSION zstd);
        """
    )
    (count,) = con.execute(f"SELECT count(*) FROM '{target}'").fetchone()
    return count


def build_authors(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths) -> dict[str, int]:
    staged = paths.staging("authors_raw")

    con.execute(
        f"""
        COPY (
          SELECT
            author_key,
            name,
            {fingerprint_sql("name")}     AS name_fp,
            {_year_sql("birth_date_raw")} AS birth_year,
            {_year_sql("death_date_raw")} AS death_year,
            revision,
            last_modified
          FROM '{staged}'
        ) TO '{paths.table("authors")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )

    con.execute(
        f"""
        COPY (
          SELECT author_key, name, {fingerprint_sql("name")} AS name_fp, 'primary' AS source
          FROM '{staged}'
          WHERE name IS NOT NULL AND name <> ''
          UNION ALL
          SELECT author_key, alt AS name, {fingerprint_sql("alt")} AS name_fp,
                 'alternate' AS source
          FROM (
            SELECT author_key, unnest(alternate_names) AS alt
            FROM '{staged}'
            WHERE alternate_names IS NOT NULL AND len(alternate_names) > 0
          )
          WHERE alt IS NOT NULL AND alt <> ''
        ) TO '{paths.table("author_names")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )

    (authors_n,) = con.execute(f"SELECT count(*) FROM '{paths.table('authors')}'").fetchone()
    (names_n,) = con.execute(f"SELECT count(*) FROM '{paths.table('author_names')}'").fetchone()
    return {"authors": authors_n, "author_names": names_n}
