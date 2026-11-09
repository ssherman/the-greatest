from typing import Annotated

from pydantic import BaseModel, Field, StringConstraints

Qid = Annotated[str, StringConstraints(pattern=r"^Q[1-9][0-9]*$", max_length=20)]
Pid = Annotated[str, StringConstraints(pattern=r"^P[1-9][0-9]*$", max_length=20)]


class ItemsRequest(BaseModel):
    ids: list[Qid] = Field(max_length=50)


class LabelsRequest(BaseModel):
    ids: list[Qid] = Field(max_length=500)


class ExternalIdRequest(BaseModel):
    pairs: list[tuple[Pid, Annotated[str, StringConstraints(max_length=200)]]] = Field(
        max_length=500
    )
    limit: int = Field(default=10, ge=1, le=100)


class LinkedFromRequest(BaseModel):
    targets: list[Qid] = Field(max_length=100)
    properties: list[Pid] = Field(default=["P50", "P800"], max_length=10)
    exclude_types: list[Qid] = Field(default=[], max_length=20)
    limit: int = Field(default=5000, ge=1, le=20000)
