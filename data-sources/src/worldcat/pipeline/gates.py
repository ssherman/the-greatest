"""The seven gates from the spec. A gate never raises; it returns a GateResult."""

from dataclasses import dataclass
from pathlib import Path

import duckdb

from common.gates import GateResult
from common.normalize import isbn_checksum_ok_sql, normalize_isbn
from worldcat.pipeline.distill import PASS_ORDER, shards_glob
from worldcat.pipeline.extract import ExtractStats
from worldcat.pipeline.paths import TABLES, WorldcatPaths

# (isbn13 or None, oclc, expected genre or None): real records chosen on the spike.
CANARIES: tuple[tuple[str | None, int, str | None], ...] = (
    ("9780735211292", 1055766559, "Nonfiction"),  # Atomic Habits
    ("9780395476901", 1000415078, None),  # The Hobbit
    ("9780553103540", 1002380292, None),  # A Game of Thrones
)
CANARY_REDIRECT = (1003236695, 37975719)


@dataclass(frozen=True)
class Thresholds:
    """Production floors. Deliberately loose for the first build; tighten them to
    the measured values afterwards and record the measurement in the feature doc."""

    min_records: int = 20_000_000
    max_records: int = 120_000_000
    min_redirects: int = 10_000_000
    min_genre_share: float = 0.25
    min_subject_share: float = 0.50
    min_year_share: float = 0.80
    min_checksum_share: float = 0.98
    min_catalogue_coverage: float = 0.80


def _one(con, sql, params=()):
    return con.execute(sql, params).fetchone()


def _row_counts(con, paths, t: Thresholds) -> GateResult:
    counts = {}
    for name in TABLES:
        target = paths.table(name)
        counts[name] = _one(con, f"SELECT count(*) FROM '{target}'")[0] if target.exists() else None
    problems = [name for name, n in counts.items() if n is None]
    if counts["records"] is not None and not (t.min_records <= counts["records"] <= t.max_records):
        problems.append(
            f"records={counts['records']:,} outside [{t.min_records:,}, {t.max_records:,}]"
        )
    if (
        counts["isbns"] is not None
        and counts["records"] is not None
        and counts["isbns"] < counts["records"]
    ):
        problems.append(f"isbns={counts['isbns']:,} < records={counts['records']:,}")
    if counts["redirects"] is not None and counts["redirects"] < t.min_redirects:
        problems.append(f"redirects={counts['redirects']:,} < {t.min_redirects:,}")
    return GateResult(
        "row_counts",
        "fail" if problems else "pass",
        "; ".join(problems) if problems else "all tables within bounds",
        {"counts": counts},
    )


def _field_coverage(con, paths, t: Thresholds) -> GateResult:
    records = paths.table("records")
    genre, subjects, year, total = _one(
        con,
        f"SELECT count(*) FILTER (WHERE genre IS NOT NULL), "
        f"count(*) FILTER (WHERE len(subjects) > 0), "
        f"count(*) FILTER (WHERE year IS NOT NULL), count(*) FROM '{records}'",
    )
    shares = {
        "genre": genre / total if total else 0,
        "subjects": subjects / total if total else 0,
        "year": year / total if total else 0,
    }
    floors = {"genre": t.min_genre_share, "subjects": t.min_subject_share, "year": t.min_year_share}
    low = [f"{k}={shares[k]:.3f} < {floors[k]}" for k in shares if shares[k] < floors[k]]
    return GateResult(
        "field_coverage",
        "fail" if low else "pass",
        "; ".join(low) or "coverage within bounds",
        shares,
    )


def _isbn_checksums(con, paths, t: Thresholds) -> GateResult:
    ok, total = _one(
        con,
        f"SELECT count(*) FILTER (WHERE {isbn_checksum_ok_sql('raw')}), count(*) "
        f"FROM (SELECT unnest(isbns_raw) AS raw FROM read_parquet('{shards_glob(paths)}') "
        f"WHERE kind = 'record')",
    )
    share = ok / total if total else 0.0
    status = "pass" if share >= t.min_checksum_share else "fail"
    return GateResult(
        "isbn_checksums",
        status,
        f"{share:.4f} of raw ISBNs pass their check digit",
        {"share_ok": share, "total": total},
    )


def _pass_prefixes(con, paths) -> GateResult:
    known = ", ".join(f"'{p}'" for p in PASS_ORDER)
    unknown = [
        r[0]
        for r in con.execute(
            f"SELECT DISTINCT pass FROM read_parquet('{shards_glob(paths)}') "
            f"WHERE pass NOT IN ({known}) AND kind = 'record'"
        ).fetchall()
    ]
    return GateResult(
        "pass_prefixes",
        "fail" if unknown else "pass",
        f"unknown: {unknown}" if unknown else "every pass prefix is ranked",
        {"unknown": unknown},
    )


def _canaries(con, paths) -> GateResult:
    missing = []
    for isbn13, oclc, genre in CANARIES:
        if (
            isbn13
            and _one(
                con,
                f"SELECT count(*) FROM '{paths.table('isbns')}' WHERE isbn13 = ? AND oclc = ?",
                [isbn13, oclc],
            )[0]
            == 0
        ):
            missing.append(f"isbn {isbn13} -> {oclc}")
        row = _one(con, f"SELECT genre FROM '{paths.table('records')}' WHERE oclc = ?", [oclc])
        if row is None:
            missing.append(f"record {oclc}")
        elif genre is not None and row[0] != genre:
            missing.append(f"record {oclc} genre {row[0]!r} != {genre!r}")
    src, dst = CANARY_REDIRECT
    redirect = _one(
        con, f"SELECT to_oclc FROM '{paths.table('redirects')}' WHERE from_oclc = ?", [src]
    )
    if redirect != (dst,):
        missing.append(f"redirect {src} -> {dst}")
    return GateResult(
        "canaries",
        "fail" if missing else "pass",
        f"missing: {missing}" if missing else "all canaries resolve",
        {"missing": missing},
    )


def _catalogue_coverage(con, paths, t: Thresholds, catalogue_isbns: Path | None) -> GateResult:
    if catalogue_isbns is None:
        return GateResult(
            "catalogue_coverage", "skipped", "no catalogue ISBN export given (--catalogue-isbns)"
        )
    if not catalogue_isbns.exists():
        return GateResult(
            "catalogue_coverage", "fail", f"catalogue ISBN export not found: {catalogue_isbns}"
        )
    wanted = sorted(
        {
            n.isbn13
            for line in catalogue_isbns.read_text().split()
            if (n := normalize_isbn(line)) is not None and n.isbn13
        }
    )
    if not wanted:
        return GateResult(
            "catalogue_coverage", "fail", f"no valid ISBN-13s in {catalogue_isbns}", {"isbns": 0}
        )
    con.execute("CREATE OR REPLACE TEMP TABLE ours (isbn13 VARCHAR)")
    con.execute("INSERT INTO ours SELECT unnest(?::VARCHAR[])", [wanted])
    (resolved,) = _one(
        con,
        f"SELECT count(DISTINCT o.isbn13) FROM ours o "
        f"JOIN '{paths.table('isbns')}' i USING (isbn13)",
    )
    con.execute("DROP TABLE ours")
    share = resolved / len(wanted)
    status = "pass" if share >= t.min_catalogue_coverage else "fail"
    return GateResult(
        "catalogue_coverage",
        status,
        f"{resolved:,} of {len(wanted):,} catalogue ISBNs resolve ({share:.3f})",
        {"isbns": len(wanted), "resolved": resolved, "share": share},
    )


def _bad_frames(extract_stats: list[ExtractStats]) -> GateResult:
    bad = [list(item) for s in extract_stats for item in s.bad_frames]
    return GateResult(
        "bad_frames",
        "fail" if bad else "pass",
        f"{len(bad)} frame(s) failed to decompress" if bad else "every frame decoded",
        {"bad_frames": bad},
    )


def _guarded(name: str, gate, *args) -> GateResult:
    """A gate that raises is a failed gate, so the build still writes its report."""
    try:
        return gate(*args)
    except Exception as exc:
        return GateResult(name, "fail", f"gate raised: {exc!r}", {"error": repr(exc)})


def run_gates(
    con: duckdb.DuckDBPyConnection,
    paths: WorldcatPaths,
    *,
    extract_stats: list[ExtractStats],
    thresholds: Thresholds,
    catalogue_isbns: Path | None,
) -> list[GateResult]:
    return [
        _guarded("row_counts", _row_counts, con, paths, thresholds),
        _guarded("field_coverage", _field_coverage, con, paths, thresholds),
        _guarded("isbn_checksums", _isbn_checksums, con, paths, thresholds),
        _guarded("pass_prefixes", _pass_prefixes, con, paths),
        _guarded("canaries", _canaries, con, paths),
        _guarded(
            "catalogue_coverage", _catalogue_coverage, con, paths, thresholds, catalogue_isbns
        ),
        _guarded("bad_frames", _bad_frames, extract_stats),
    ]


def gates_passed(results: list[GateResult]) -> bool:
    return all(r.status != "fail" for r in results)
