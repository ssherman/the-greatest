"""Request and response bodies for POST /fetch (spec §2).

No `from __future__ import annotations` here or in routes.py: FastAPI must see
real classes, and the request model is built per app so that its timeout
bounds come from Settings.
"""

from typing import Literal

from pydantic import BaseModel, ConfigDict, Field

from fetcher.settings import MIN_TIMEOUT_MS, Settings


def fetch_request_model(settings: Settings) -> type[BaseModel]:
    class FetchRequestBody(BaseModel):
        # Unknown fields are a 422 naming the field, the same rule as /resolve.
        model_config = ConfigDict(extra="forbid")

        url: str = Field(min_length=1, max_length=8192)
        wait_until: Literal["domcontentloaded", "load", "networkidle"] = "load"
        wait_for_selector: str | None = Field(default=None, min_length=1, max_length=1000)
        timeout_ms: int = Field(
            default=settings.default_timeout_ms, ge=MIN_TIMEOUT_MS, le=settings.max_timeout_ms
        )

    return FetchRequestBody


class FetchResponseBody(BaseModel):
    url: str
    final_url: str
    status: int
    title: str
    html: str
    selector_found: bool | None
    elapsed_ms: int
    fetched_at: str


class ErrorBody(BaseModel):
    error: str
    detail: str
