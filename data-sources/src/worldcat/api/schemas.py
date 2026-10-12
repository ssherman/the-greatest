from pydantic import BaseModel, Field


class Holdings(BaseModel):
    total_holding_count: int
    total_editions: int | None = None


class Record(BaseModel):
    oclc: int
    title: str | None = None
    subtitle: str | None = None
    creator: str | None = None
    contributors: list[str] = []
    year: int | None = None
    publication_date_raw: str | None = None
    publisher: str | None = None
    publication_place: str | None = None
    cataloging_language: str | None = None
    specific_format: str | None = None
    edition_statement: str | None = None
    physical_description: str | None = None
    series: str | None = None
    genre: str | None = None
    subjects: list[str] = []
    isbn13s: list[str] = []
    merged_oclc: list[int] = []
    other_format_oclc: list[int] = []
    total_editions: int | None = None
    summary: str | None = None
    source_type: str | None = None
    holdings: Holdings | None = None
    redirected_from: int | None = None


class IsbnResponse(BaseModel):
    isbn13: str
    records: list[Record]


class LookupRequest(BaseModel):
    isbn13s: list[str] = Field(max_length=500)


class LookupResponse(BaseModel):
    results: dict[str, list[Record]]
