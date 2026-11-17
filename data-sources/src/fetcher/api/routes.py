"""POST /fetch, POST /fetch_file and GET /health (spec §2).

No `from __future__ import annotations`: the request body's class is built at
runtime from Settings, and FastAPI must see that real class in the signature.
"""

import base64
from dataclasses import asdict

from fastapi import APIRouter

from fetcher.api.schemas import (
    ErrorBody,
    FetchResponseBody,
    FileFetchResponseBody,
    fetch_file_request_model,
    fetch_request_model,
)
from fetcher.fetcher import Fetcher, FetchRequest, FileFetchRequest

ERROR_RESPONSES = {status: {"model": ErrorBody} for status in (400, 502, 503, 504)}


def build_router(fetcher: Fetcher) -> APIRouter:
    router = APIRouter()
    FetchRequestBody = fetch_request_model(fetcher.settings)
    FileFetchRequestBody = fetch_file_request_model(fetcher.settings)

    @router.post("/fetch", response_model=FetchResponseBody, responses=ERROR_RESPONSES)
    async def fetch(body: FetchRequestBody) -> FetchResponseBody:
        result = await fetcher.fetch(FetchRequest(**body.model_dump()))
        return FetchResponseBody(**asdict(result))

    @router.post("/fetch_file", response_model=FileFetchResponseBody, responses=ERROR_RESPONSES)
    async def fetch_file(body: FileFetchRequestBody) -> FileFetchResponseBody:
        result = await fetcher.fetch_file(FileFetchRequest(**body.model_dump()))
        fields = asdict(result)
        raw = fields.pop("body")
        return FileFetchResponseBody(**fields, body_base64=base64.b64encode(raw).decode("ascii"))

    @router.get("/health")
    def health() -> dict:
        return fetcher.health()

    return router
