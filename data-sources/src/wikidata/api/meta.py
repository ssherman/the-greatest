from fastapi import APIRouter, Depends

from wikidata.api.deps import SOURCE, ArtifactState, get_state
from wikidata.pipeline.report import PIPELINE_VERSION

router = APIRouter()


@router.get("/version")
def version(state: ArtifactState = Depends(get_state)) -> dict:
    return {
        "source": SOURCE,
        "dump_date": state.manifest.get("dump_date"),
        "pipeline_version": PIPELINE_VERSION,
        "redirects_dump_date": state.manifest.get("redirects_dump_date"),
        "built_at": state.manifest.get("built_at"),
        "gates_passed": state.manifest.get("gates_passed"),
        "tables": state.manifest.get("tables", {}),
        "gates": state.report.get("gates", []),
    }
