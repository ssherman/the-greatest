from pydantic import BaseModel, Field


class ItemsRequest(BaseModel):
    ids: list[str] = Field(max_length=50)


class LabelsRequest(BaseModel):
    ids: list[str] = Field(max_length=500)


class ExternalIdRequest(BaseModel):
    pairs: list[tuple[str, str]] = Field(max_length=500)
    limit: int = Field(default=10, ge=1, le=100)


class LinkedFromRequest(BaseModel):
    targets: list[str] = Field(max_length=100)
    properties: list[str] = Field(default=["P50", "P800"], max_length=10)
    exclude_types: list[str] = Field(default=[], max_length=20)
    limit: int = Field(default=5000, ge=1, le=20000)
