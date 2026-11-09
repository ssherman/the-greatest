"""The build gates. A gate never raises; it returns a GateResult."""

import duckdb

from common.gates import GateResult, within_tolerance
from wikidata.pipeline.classes import closure_table
from wikidata.pipeline.config import KeptConfig
from wikidata.pipeline.normalize import normalize_name
from wikidata.pipeline.paths import TABLES, WikidataPaths

# Real records, verified against the 2026-11 dump.
WORK, WORK_COUNTRY = "Q622400", "Q145"  # Things Fall Apart: country of origin
AUTHOR, AUTHOR_NAME, AUTHOR_VIAF = "Q155845", "Chinua Achebe", "24596756"
COUNTRY, COUNTRY_ISO = "Q1033", "NG"  # Nigeria: ISO 3166-1 alpha-2

MAX_DROP = 0.15
MAX_RISE = 0.15
MAX_ROW_GROUP_BYTES = 64 * 1024 * 1024


def gates_passed(results: list[GateResult]) -> bool:
    return all(r.status != "fail" for r in results)


def _one(con, sql, params=()):
    return con.execute(sql, params).fetchone()


def _row_counts(con, paths, previous_counts) -> GateResult:
    counts = {t: _one(con, f"SELECT count(*) FROM '{paths.staged(t)}'")[0] for t in TABLES}
    problems = [f"{t} is empty" for t, n in counts.items() if n == 0]
    for table, n in counts.items():
        previous = (previous_counts or {}).get(table)
        if not within_tolerance(previous, n, max_drop=MAX_DROP, max_rise=MAX_RISE):
            problems.append(f"{table}: {n} vs {previous} in the previous version")
    return GateResult(
        "row_counts", "fail" if problems else "pass", "; ".join(problems) or "counts ok", counts
    )


def _claim_values(con, paths, qid: str, prop: str, path: str) -> list[str]:
    row = _one(
        con,
        f"SELECT json_extract_string(claims, '$.{prop}[*].mainsnak.datavalue.value{path}') "
        f"FROM '{paths.staged('items')}' WHERE qid = ?",
        [qid],
    )
    return list(row[0]) if row and row[0] else []


def _canaries(con, paths) -> GateResult:
    missing = []
    if WORK_COUNTRY not in _claim_values(con, paths, WORK, "P495", ".id"):
        missing.append(f"{WORK} P495 {WORK_COUNTRY}")
    name_hit = _one(
        con,
        f"SELECT count(*) FROM '{paths.staged('names')}' WHERE name = ? AND qid = ?",
        [normalize_name(AUTHOR_NAME), AUTHOR],
    )[0]
    if not name_hit:
        missing.append(f"name {AUTHOR_NAME!r} -> {AUTHOR}")
    viaf_hit = _one(
        con,
        f"SELECT count(*) FROM '{paths.staged('external_ids')}' "
        "WHERE property = 'P214' AND value = ? AND qid = ?",
        [AUTHOR_VIAF, AUTHOR],
    )[0]
    if not viaf_hit:
        missing.append(f"VIAF {AUTHOR_VIAF} -> {AUTHOR}")
    link_hit = _one(
        con,
        f"SELECT count(*) FROM '{paths.staged('links')}' "
        "WHERE property = 'P50' AND target = ? AND source = ?",
        [AUTHOR, WORK],
    )[0]
    if not link_hit:
        missing.append(f"P50 link {WORK} -> {AUTHOR}")
    if COUNTRY_ISO not in _claim_values(con, paths, COUNTRY, "P297", ""):
        missing.append(f"{COUNTRY} P297 {COUNTRY_ISO}")
    if _one(con, f"SELECT count(*) FROM '{paths.staged('redirects')}'")[0] == 0:
        missing.append("no redirect")
    return GateResult(
        "canaries",
        "fail" if missing else "pass",
        f"missing: {missing}" if missing else "all canaries resolve",
        {"missing": missing},
    )


SAMPLE_LIMIT = 20


def _no_excluded_types(con, paths, config: KeptConfig) -> GateResult:
    """Applies distill's rule (`_kept_set`): a person-typed item is kept whatever else it is typed
    as (Wikidata has persons also typed as scholarly articles), so only a non-person item typed
    under an excluded root is a violation."""
    items = paths.staged("items")
    people = "[" + ", ".join(f"'{t}'" for t in sorted(config.person_types)) + "]"
    con.execute(
        "CREATE OR REPLACE TEMP TABLE _edges AS "
        f"SELECT qid AS child, unnest(subclass_of) AS parent FROM '{items}'"
    )
    closure_table(con, "_excluded", config.excluded_roots, "_edges")
    con.execute(
        "CREATE OR REPLACE TEMP TABLE _violations AS "
        f"SELECT qid, list_concat(types, forms) AS all_types FROM '{items}' "
        f"WHERE NOT list_has_any(types, {people}) "
        "AND list_has_any(list_concat(types, forms), (SELECT list(cls) FROM _excluded))"
    )
    (bad,) = _one(con, "SELECT count(*) FROM _violations")
    samples = [
        {"qid": qid, "types": list(types)}
        for qid, types in con.execute(
            f"SELECT qid, all_types FROM _violations ORDER BY qid LIMIT {SAMPLE_LIMIT}"
        ).fetchall()
    ]
    return GateResult(
        "no_excluded_types",
        "fail" if bad else "pass",
        f"{bad} items typed under an excluded root" if bad else "no excluded types in items",
        {"violations": bad, "samples": samples},
    )


def _row_group_sizes(con, paths) -> GateResult:
    (biggest,) = _one(
        con,
        "SELECT coalesce(max(size), 0) FROM (SELECT sum(total_uncompressed_size) AS size "
        f"FROM parquet_metadata('{paths.staged('items')}') GROUP BY row_group_id)",
    )
    return GateResult(
        "row_group_sizes",
        "fail" if biggest > MAX_ROW_GROUP_BYTES else "pass",
        f"largest items row group is {int(biggest):,} bytes (limit {MAX_ROW_GROUP_BYTES:,})",
        {"largest_bytes": int(biggest)},
    )


def run_gates(
    paths: WikidataPaths,
    config: KeptConfig,
    previous_counts: dict | None,
    *,
    fixture: bool = False,
) -> list[GateResult]:
    """Gates read the staged tables: they run before anything is promoted."""
    con = duckdb.connect(database=":memory:")
    try:
        canaries = (
            GateResult("canaries", "skipped", "fixture build") if fixture else _canaries(con, paths)
        )
        return [
            _row_counts(con, paths, previous_counts),
            canaries,
            _no_excluded_types(con, paths, config),
            _row_group_sizes(con, paths),
        ]
    finally:
        con.close()
