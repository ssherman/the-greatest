"""Request and response bodies for POST /fetch and POST /fetch_file (spec §2).

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


def fetch_file_request_model(settings: Settings) -> type[BaseModel]:
    class FileFetchRequestBody(BaseModel):
        model_config = ConfigDict(extra="forbid")

        url: str = Field(min_length=1, max_length=8192)
        page_url: str | None = Field(default=None, min_length=1, max_length=8192)
        timeout_ms: int = Field(
            default=settings.default_timeout_ms, ge=MIN_TIMEOUT_MS, le=settings.max_timeout_ms
        )

    return FileFetchRequestBody


class FetchResponseBody(BaseModel):
    url: str
    final_url: str
    status: int
    title: str
    html: str
    selector_found: bool | None
    elapsed_ms: int
    fetched_at: str


class FileFetchResponseBody(BaseModel):
    url: str
    final_url: str
    status: int
    content_type: str | None
    body_base64: str  # standard base64 with padding
    size_bytes: int
    elapsed_ms: int
    fetched_at: str


class ErrorBody(BaseModel):
    error: str
    detail: str
