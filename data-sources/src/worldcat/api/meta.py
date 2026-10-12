from fastapi import APIRouter, Depends

from worldcat.api.deps import SOURCE, ArtifactState, get_state
from worldcat.pipeline.report import PIPELINE_VERSION

router = APIRouter()


@router.get("/version")
def version(state: ArtifactState = Depends(get_state)) -> dict:
    return {
        "source": SOURCE,
        "dump_date": state.manifest.get("dump_date"),
        "pipeline_version": PIPELINE_VERSION,
        "built_at": state.manifest.get("built_at"),
        "gates_passed": state.manifest.get("gates_passed"),
        "source_fingerprint": state.manifest.get("source_fingerprint"),
        "tables": state.manifest.get("tables", {}),
        "gates": state.report.get("gates", []),
    }
