from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from worldcat.api import meta, retrieval
from worldcat.api.deps import ArtifactState, Settings, open_artifact


def create_app(state: ArtifactState | None = None) -> FastAPI:
    artifact_state = state or open_artifact(Settings.from_env())

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        yield
        artifact_state.connection.close()

    app = FastAPI(title="WorldCat data service", version="0.1.0", lifespan=lifespan)
    app.state.artifact = artifact_state
    app.include_router(meta.router)
    app.include_router(retrieval.router)
    return app


def factory() -> FastAPI:
    return create_app()
