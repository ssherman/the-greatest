"""build_report.json (everything) and manifest.json (what the server and Rails check)."""

import datetime
import json

import duckdb

from common.gates import GateResult
from wikidata.pipeline.gates import gates_passed
from wikidata.pipeline.paths import TABLES, WikidataPaths

PIPELINE_VERSION = 1


def now() -> str:
    return datetime.datetime.now(datetime.UTC).isoformat()


def table_stats(paths: WikidataPaths) -> dict:
    """Stats of the promoted tables (call after promotion)."""
    con = duckdb.connect(database=":memory:")
    try:
        out = {}
        for name in TABLES:
            target = paths.table(name)
            (rows,) = con.execute(f"SELECT count(*) FROM '{target}'").fetchone()
            out[name] = {"rows": rows, "bytes": target.stat().st_size}
        return out
    finally:
        con.close()


def gate_dicts(results: list[GateResult]) -> list[dict]:
    return [
        {"name": g.name, "status": g.status, "detail": g.detail, "observed": g.observed}
        for g in results
    ]


def write_build_report(
    paths: WikidataPaths, *, dump_date: str, results: list[GateResult], timings: dict, tables: dict
) -> dict:
    report = {
        "dump_date": dump_date,
        "built_at": now(),
        "pipeline_version": PIPELINE_VERSION,
        "tables": tables,
        "total_bytes": sum(t["bytes"] for t in tables.values()),
        "gates": gate_dicts(results),
        "timings": timings,
    }
    paths.report_path.write_text(json.dumps(report, indent=2, default=str))
    return report


def manifest_dict(dump_date: str, results: list[GateResult], counts: dict[str, int]) -> dict:
    return {
        "dump_date": dump_date,
        "built_at": now(),
        "pipeline_version": PIPELINE_VERSION,
        "tables": counts,
        "gates": gate_dicts(results),
        "gates_passed": gates_passed(results),
    }


def write_manifest(paths: WikidataPaths, manifest: dict) -> None:
    paths.manifest_path.write_text(json.dumps(manifest, indent=2, default=str))
