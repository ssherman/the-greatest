"""The page fetcher service (spec: 2026-09-26-page-fetcher-service-design.md).

URL in, rendered HTML out. A pure function of the request: no cache, no state
between calls, one fresh browser per fetch.
"""

from __future__ import annotations

import logging
from collections.abc import AsyncIterator
from contextlib import asynccontextmanager

from fastapi import FastAPI, Request
from fastapi.responses import JSONResponse

from fetcher import __version__
from fetcher.api.routes import build_router
from fetcher.fetcher import Fetcher, FetchError
from fetcher.settings import Settings


def create_app(fetcher: Fetcher | None = None) -> FastAPI:
    if fetcher is None:
        from fetcher.browser import CamoufoxBrowser

        settings = Settings.from_env()
        fetcher = Fetcher(settings, CamoufoxBrowser(locale=settings.locale))
    service = fetcher

    @asynccontextmanager
    async def lifespan(app: FastAPI) -> AsyncIterator[None]:
        await service.start()
        try:
            yield
        finally:
            await service.stop()

    app = FastAPI(title="Page fetcher", version=__version__, lifespan=lifespan)
    app.state.fetcher = service
    app.include_router(build_router(service))

    @app.exception_handler(FetchError)
    async def fetch_error(request: Request, exc: FetchError) -> JSONResponse:
        return JSONResponse(
            status_code=exc.http_status, content={"error": exc.code, "detail": exc.detail}
        )

    return app


def factory() -> FastAPI:
    # uvicorn configures only its own loggers; the one-line-per-fetch log
    # (spec §9) needs the "fetcher" logger to reach stdout as well.
    logging.basicConfig(level=logging.INFO, format="%(message)s")
    return create_app()
