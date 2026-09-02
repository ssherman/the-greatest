"""works dump -> works.parquet + work_details.parquet.

Stage A reads the .gz once (measured: 1.2 min for 41.5M works). Stage B derives
everything else from Parquet. Two facts from the real dump drive the extraction:

  * `description` is an object -- {"type": "/type/text", "value": "..."} -- in
    ~97% of works that have one, and a bare string in the rest. Extracting
    '$.description' alone yields the serialized object, silently.
  * 352 author entries per 300,000 works have no "author" key at all. The
    JSON wildcard drops them; this module counts what it dropped.

`subjects` is extracted with the `$.subjects[*]` wildcard path, not the plain
`$.subjects`: `json_extract_string` only returns a genuine `VARCHAR[]` for a
wildcard path. A plain path returns the serialized JSON array as one VARCHAR.
"""

from __future__ import annotations

import duckdb

from common.normalize import fingerprint_sql, title_noart_sql, title_nosub_sql

from .paths import ArtifactPaths

_DUMP_COLUMNS = (
    "{'column0':'VARCHAR','column1':'VARCHAR','column2':'VARCHAR',"
    "'column3':'VARCHAR','column4':'VARCHAR'}"
)


def read_dump_sql(path) -> str:
    """Every 5-column OL dump reads the same way. quote='' and escape='' are
    required: the dumps are raw TSV and DuckDB would otherwise treat a double
    quote inside a JSON payload as a quoted field."""
    return (
        f"read_csv('{path}', delim='\\t', header=false, quote='', escape='', "
        f"columns={_DUMP_COLUMNS})"
    )


def stage_works(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths) -> int:
    source = read_dump_sql(paths.dump("works"))
    target = paths.staging("works_raw")
    con.execute(
        f"""
        COPY (
          SELECT
            replace(column1, '/works/', '')                          AS work_key,
            json_extract_string(column4, '$.title')                  AS title,
            json_extract_string(column4, '$.subtitle')               AS subtitle,
            COALESCE(
              json_extract_string(column4, '$.description.value'),
              json_extract_string(column4, '$.description')
            )                                                        AS description,
            json_extract_string(column4, '$.first_publish_date')     AS first_publish_date_raw,
            json_extract_string(column4, '$.subjects[*]')            AS subjects,
            list_transform(
              json_extract_string(column4, '$.authors[*].author.key'),
              x -> replace(x, '/authors/', '')
            )                                                        AS author_keys,
            COALESCE(json_array_length(column4, '$.authors'), 0)     AS author_entry_count,
            TRY_CAST(column2 AS INTEGER)                             AS revision,
            TRY_CAST(column3 AS DATE)                                AS last_modified
          FROM {source}
          WHERE column0 = '/type/work'
        ) TO '{target}' (FORMAT parquet, COMPRESSION zstd);
        """
    )
    (count,) = con.execute(f"SELECT count(*) FROM '{target}'").fetchone()
    return count


def build_works(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths) -> dict[str, int]:
    staged = paths.staging("works_raw")

    fp_full = fingerprint_sql("title")
    fp_nosub = title_nosub_sql("title")
    fp_noart = title_noart_sql("title")

    con.execute(
        f"""
        COPY (
          WITH fingerprinted AS (
            SELECT
              work_key,
              title,
              {fp_full}  AS title_fp,
              {fp_nosub} AS title_fp_nosub,
              {fp_noart} AS title_fp_noart,
              CAST(COALESCE(len(author_keys), 0) AS SMALLINT) AS author_count,
              revision,
              last_modified
            FROM '{staged}'
          )
          SELECT
            work_key, title, title_fp, title_fp_nosub, title_fp_noart,
            CAST(count(*) OVER (PARTITION BY title_fp)       AS INTEGER) AS title_fp_freq,
            CAST(count(*) OVER (PARTITION BY title_fp_nosub) AS INTEGER) AS title_fp_nosub_freq,
            CAST(count(*) OVER (PARTITION BY title_fp_noart) AS INTEGER) AS title_fp_noart_freq,
            author_count, revision, last_modified
          FROM fingerprinted
        ) TO '{paths.table("works")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )

    con.execute(
        f"""
        COPY (
          SELECT
            work_key,
            subtitle,
            description,
            first_publish_date_raw,
            TRY_CAST(regexp_extract(first_publish_date_raw, '(-?\\d{{1,4}})', 1) AS INTEGER)
              AS declared_year,
            subjects
          FROM '{staged}'
          WHERE subtitle IS NOT NULL
             OR description IS NOT NULL
             OR first_publish_date_raw IS NOT NULL
             OR (subjects IS NOT NULL AND len(subjects) > 0)
        ) TO '{paths.table("work_details")}' (FORMAT parquet, COMPRESSION zstd);
        """
    )

    (works_n,) = con.execute(f"SELECT count(*) FROM '{paths.table('works')}'").fetchone()
    (details_n,) = con.execute(f"SELECT count(*) FROM '{paths.table('work_details')}'").fetchone()
    (dropped,) = con.execute(
        f"SELECT COALESCE(sum(author_entry_count - COALESCE(len(author_keys), 0)), 0) "
        f"FROM '{staged}'"
    ).fetchone()

    return {
        "works": works_n,
        "work_details": details_n,
        "dropped_author_entries": int(dropped),
    }
