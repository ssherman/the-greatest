"""GET /version -- what data, what code, and how well it scored."""

from __future__ import annotations

import json
from pathlib import Path

from fastapi import APIRouter, Depends

from openlibrary.api.deps import ArtifactState, get_state

router = APIRouter()


@router.get("/version")
def version(state: ArtifactState = Depends(get_state)) -> dict:
    report_path = state.paths.report_path
    tables = {}
    if report_path.exists():
        tables = json.loads(report_path.read_text()).get("tables", {})

    thresholds_path = Path(__file__).resolve().parents[1] / "eval" / "thresholds.json"
    evaluation = json.loads(thresholds_path.read_text()) if thresholds_path.exists() else {}

    return {
        **state.source_version.model_dump(),
        "built_at": state.manifest.get("built_at"),
        "gates_passed": state.manifest.get("gates_passed"),
        "tables": tables,
        "eval": evaluation,
    }
