"""GET /version -- what data, what code, and how well it scored.

The one unenveloped response: its fields ARE the version, so there is no
`source_version` wrapper around them. Everything here comes from
`ArtifactState`, read once at boot (`deps.open_artifact`) -- nothing on
disk is touched per request.

  * `built_at` / `gates_passed`: this build's manifest.
  * `tables`: per-table row counts and bytes from this build's
    build_report.json.
  * `gates`: this build's per-gate results (name, status, detail,
    observed) from the same report -- including a `skipped` gate that
    `gates_passed: true` alone would hide (the 2026-07-31 build skipped
    `evaluation_set`).
  * `eval`: the CODE's calibration record, `eval/thresholds.json` --
    pinned and measured for the running matcher version -- not this
    artifact's gate run.
"""

from __future__ import annotations

from fastapi import APIRouter, Depends

from openlibrary.api.deps import ArtifactState, get_state

router = APIRouter()


@router.get("/version")
def version(state: ArtifactState = Depends(get_state)) -> dict:
    return {
        **state.source_version.model_dump(),
        "built_at": state.manifest.get("built_at"),
        "gates_passed": state.manifest.get("gates_passed"),
        "tables": state.report.get("tables", {}),
        "gates": state.report.get("gates", []),
        "eval": state.eval_thresholds,
    }
