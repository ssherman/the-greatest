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

# `first_publish_date_raw` is free text ("December 31, 1991", "-350", "ca.
# 1900", "1991-1995", ...), and `declared_year` is extracted from it with a
# regex. The original pattern, `(-?\d{1,4})`, took the FIRST digit run in the
# string -- which for a spelled-out date is the day, not the year:
# "December 31, 1991" -> 31, "July 3, 2003" -> 3, "May 1, 1990" -> 1. Measured
# against the production dump (22,448,953-row work_details table, ~4.4M of
# those rows carrying a non-null first_publish_date_raw): that bug put
# 241,714 rows' declared_year below 1000 (1.08% of the table). This pattern
# instead matches a four-digit run, or a NEGATIVE one-to-four-digit run for
# ancient/BCE works (e.g. "-350"). Regex alternation is leftmost-first, so a
# four-digit year embedded anywhere in the text wins over a shorter leading
# number: "December 31, 1991" -> 1991, "1991-1995" -> 1991, a bare "31" or
# "19uu" -> NULL (no 4-digit run, so nothing plausible to extract). Simulated
# over the same ~4.4M dated rows, this cuts declared_year < 1000 from 241,714
# to 87 (99.96% reduction) and turns zero rows NULL that were not already
# unmatched under the old pattern.
#
# Residual, accepted rather than fixed: a hyphen used as a DATE SEPARATOR
# still reads as a negative sign, e.g. "12-12-2008" -> -12 and
# "OCTOBER-2008" -> -2008 (measured at 7 rows in ~4.4M). DuckDB's RE2 engine
# has no lookaround to tell a separator hyphen from a sign hyphen, and a
# plausibility bound can't help either -- -12 is a legitimate declared year
# for an ancient work, so there is no threshold that rejects the separator
# case without also rejecting real ones. Do not "simplify" this back to
# `(-?\d{1,4})`; that reintroduces the 241,714-row regression above.
_DECLARED_YEAR_PATTERN = r"(-\d{1,4}|\d{4})"


# DuckDB's read_csv defaults to a 2 MB line cap. The real editions dump has at
# least one record at 2,005,928 bytes -- just over the default -- so the cap
# has to move, and deliberately not tuned tight to that one observed record:
# the next oversized record we have not seen yet should not fail the same way.
#
# 64 MiB was the first choice (the box building the real artifact has 45 GB of
# RAM, so it costs nothing there), but DuckDB's read_csv pre-allocates a
# buffer that scales with max_line_size regardless of actual line lengths --
# and every fixture-based test in this project's suite (Tasks 1-14, not this
# task's to change) connects at memory_limit="1GB". Measured empirically
# against the real stage_works/stage_authors/stage_editions COPY queries (not
# a bare read_csv count, which has a much smaller footprint and understates
# this): the OOM cliff for those queries at a 1 GB limit sits at ~29.75-29.8
# MiB. 64 MiB, and even the 32 MiB first tried here, both land past that
# cliff and OOM every one of those tests before a single fixture row is
# read. 16 MiB stays clear of the cliff with real margin (~14 MiB / 46%
# headroom) while still 8x the observed overflow -- the same
# over-provisioning logic the 64 MiB choice was reaching for, sized to a
# figure the test suite can actually run under.
MAX_LINE_SIZE = 16 * 1024 * 1024


def read_dump_sql(path) -> str:
    """Every 5-column OL dump reads the same way. quote='' and escape='' are
    required: the dumps are raw TSV and DuckDB would otherwise treat a double
    quote inside a JSON payload as a quoted field."""
    return (
        f"read_csv('{path}', delim='\\t', header=false, quote='', escape='', "
        f"max_line_size={MAX_LINE_SIZE}, columns={_DUMP_COLUMNS})"
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
            TRY_CAST(regexp_extract(first_publish_date_raw, '{_DECLARED_YEAR_PATTERN}', 1)
                     AS INTEGER)                                     AS declared_year,
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
