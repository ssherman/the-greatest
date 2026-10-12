"""build_report.json (everything) and manifest.json (what the API checks at boot)."""

import datetime
import json
from dataclasses import dataclass, field

import duckdb

from common.gates import GateResult
from worldcat.pipeline.extract import ExtractStats
from worldcat.pipeline.gates import gates_passed
from worldcat.pipeline.paths import TABLES, WorldcatPaths

PIPELINE_VERSION = 1


@dataclass
class StageTimings:
    stages: dict[str, dict] = field(default_factory=dict)

    def record(self, name: str, seconds: float, rows: int | None = None) -> None:
        self.stages[name] = {"seconds": round(seconds, 3), "rows": rows}

    def as_dict(self) -> dict:
        return dict(self.stages)


def _table_stats(con: duckdb.DuckDBPyConnection, paths: WorldcatPaths) -> dict:
    out = {}
    for name in TABLES:
        target = paths.table(name)
        if not target.exists():
            out[name] = {"rows": 0, "bytes": 0, "missing": True}
            continue
        (rows,) = con.execute(f"SELECT count(*) FROM '{target}'").fetchone()
        out[name] = {"rows": rows, "bytes": target.stat().st_size}
    return out


def _now() -> str:
    return datetime.datetime.now(datetime.UTC).isoformat()


def write_build_report(
    con,
    paths: WorldcatPaths,
    *,
    dump_date: str,
    source_fingerprint: str,
    gate_results: list[GateResult],
    timings: StageTimings,
    extract: list[ExtractStats],
) -> dict:
    tables = _table_stats(con, paths)
    report = {
        "dump_date": dump_date,
        "built_at": _now(),
        "pipeline_version": PIPELINE_VERSION,
        "source_fingerprint": source_fingerprint,
        "tables": tables,
        "total_bytes": sum(t["bytes"] for t in tables.values()),
        "extract": {
            "lines": sum(s.lines for s in extract),
            "kept": sum(s.kept for s in extract),
            "bad_frames": [list(b) for s in extract for b in s.bad_frames],
        },
        "gates": [
            {"name": g.name, "status": g.status, "detail": g.detail, "observed": g.observed}
            for g in gate_results
        ],
        "timings": timings.as_dict(),
    }
    paths.report_path.write_text(json.dumps(report, indent=2, default=str))
    return report


def write_manifest(
    paths: WorldcatPaths,
    *,
    dump_date: str,
    source_fingerprint: str,
    gate_results: list[GateResult],
    timings: StageTimings,
    tables: dict,
) -> dict:
    manifest = {
        "dump_date": dump_date,
        "built_at": _now(),
        "pipeline_version": PIPELINE_VERSION,
        "source_fingerprint": source_fingerprint,
        "gates_passed": gates_passed(gate_results),
        "tables": {name: stats.get("rows", 0) for name, stats in tables.items()},
        "stages": list(timings.as_dict()),
    }
    paths.manifest_path.write_text(json.dumps(manifest, indent=2, default=str))
    return manifest
