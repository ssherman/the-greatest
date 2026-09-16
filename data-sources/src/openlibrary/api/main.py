"""The Open Library data service.

Boundaries, enforced structurally rather than by convention:
  * No endpoint mutates anything. There are no write methods.
  * No resolve returns a single answer -- always a list, so a guess can never be
    mistaken for a fact.
  * Nothing is cached server-side beyond the artifact, so the service is a pure
    function of (request, source_version) and the evaluation set is a
    regression suite for it.
"""

from __future__ import annotations

from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI

from openlibrary.api import meta, retrieval
from openlibrary.api.deps import ArtifactState, Settings, open_artifact


def create_app(state: ArtifactState | None = None) -> FastAPI:
    artifact_state = state or open_artifact(Settings.from_env())

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        yield
        artifact_state.connection.close()

    app = FastAPI(title="Open Library data service", version="0.1.0", lifespan=lifespan)
    app.state.artifact = artifact_state
    app.include_router(meta.router)
    app.include_router(retrieval.router)
    return app


def factory() -> FastAPI:
    return create_app()
