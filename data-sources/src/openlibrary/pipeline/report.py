"""manifest.json and build_report.json.

The build report is half of Increment 1's deliverable. Parquet size is a
MEASURED output, not a design assumption -- the spec's "5-8 GB" is an estimate
and this file is where the real number comes from.

Normalizer and pipeline are versioned separately so that when a re-run produces
different answers, "did the data change or did the code?" has an answer.
"""

from __future__ import annotations

import datetime
import json
from dataclasses import dataclass, field
from pathlib import Path

from common.gates import GateResult
from common.normalize import NORMALIZER_VERSION

from .paths import TABLES, ArtifactPaths

PIPELINE_VERSION = 1


@dataclass
class StageTimings:
    stages: dict[str, dict] = field(default_factory=dict)

    def record(self, name: str, seconds: float, rows: int | None = None) -> None:
        self.stages[name] = {"seconds": round(seconds, 3), "rows": rows}

    def as_dict(self) -> dict:
        return dict(self.stages)


def _table_stats(con, paths: ArtifactPaths) -> dict[str, dict]:
    stats: dict[str, dict] = {}
    for table in TABLES:
        path = paths.table(table)
        if not path.exists():
            stats[table] = {"rows": 0, "bytes": 0, "missing": True}
            continue
        (rows,) = con.execute(f"SELECT count(*) FROM '{path}'").fetchone()
        stats[table] = {"rows": rows, "bytes": path.stat().st_size}
    return stats


def write_build_report(
    con,
    paths: ArtifactPaths,
    *,
    dump_date: str,
    gate_results: list[GateResult],
    timings: StageTimings,
) -> dict:
    tables = _table_stats(con, paths)
    coverage = next(
        (g.observed for g in gate_results if g.name == "field_coverage"),
        {},
    )
    report = {
        "dump_date": dump_date,
        "built_at": datetime.datetime.now(datetime.UTC).isoformat(),
        "normalizer_version": NORMALIZER_VERSION,
        "pipeline_version": PIPELINE_VERSION,
        "tables": tables,
        "total_bytes": sum(t["bytes"] for t in tables.values()),
        "coverage": coverage,
        "gates": [
            {"name": g.name, "status": g.status, "detail": g.detail, "observed": g.observed}
            for g in gate_results
        ],
        "timings": timings.as_dict(),
    }
    paths.report_path.write_text(json.dumps(report, indent=2, default=str))
    return report


def write_manifest(
    paths: ArtifactPaths,
    *,
    dump_date: str,
    gate_results: list[GateResult],
    timings: StageTimings,
) -> dict:
    """The small file the API reads at startup. Deliberately not the full report."""
    manifest = {
        "dump_date": dump_date,
        "built_at": datetime.datetime.now(datetime.UTC).isoformat(),
        "normalizer_version": NORMALIZER_VERSION,
        "pipeline_version": PIPELINE_VERSION,
        "gates_passed": all(g.status != "fail" for g in gate_results),
        "stages": list(timings.as_dict()),
    }
    paths.manifest_path.write_text(json.dumps(manifest, indent=2, default=str))
    return manifest


def load_previous_report(root: Path, *, before_dump_date: str) -> dict | None:
    versions = root / "versions"
    if not versions.is_dir():
        return None
    candidates = sorted(d for d in versions.iterdir() if d.is_dir() and d.name < before_dump_date)
    for directory in reversed(candidates):
        report = directory / "build_report.json"
        if report.exists():
            return json.loads(report.read_text())
    return None
