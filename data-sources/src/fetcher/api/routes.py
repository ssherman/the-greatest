"""POST /fetch and GET /health (spec §2).

No `from __future__ import annotations`: the request body's class is built at
runtime from Settings, and FastAPI must see that real class in the signature.
"""

from dataclasses import asdict

from fastapi import APIRouter

from fetcher.api.schemas import ErrorBody, FetchResponseBody, fetch_request_model
from fetcher.fetcher import Fetcher, FetchRequest

ERROR_RESPONSES = {status: {"model": ErrorBody} for status in (400, 502, 503, 504)}


def build_router(fetcher: Fetcher) -> APIRouter:
    router = APIRouter()
    FetchRequestBody = fetch_request_model(fetcher.settings)

    @router.post("/fetch", response_model=FetchResponseBody, responses=ERROR_RESPONSES)
    async def fetch(body: FetchRequestBody) -> FetchResponseBody:
        result = await fetcher.fetch(FetchRequest(**body.model_dump()))
        return FetchResponseBody(**asdict(result))

    @router.get("/health")
    def health() -> dict:
        return fetcher.health()

    return router
