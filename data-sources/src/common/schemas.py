"""Response shapes shared by every source.

Three properties, each cheap now and expensive to retrofit:

  * NAMESPACED KEYS -- {"source": "openlibrary", "key": "OL81205W"}, never a
    bare work_key. The day a second source exists, "OL81205W" alone is ambiguous.
  * SOURCE VERSION on every response, so a stored result is traceable to the
    dump and the code that produced it.
  * REDIRECT TRANSPARENCY -- a merged key returns the terminal record plus
    redirected_from, so the 9.9% stale keys resolve instead of 404ing, VISIBLY.
"""

from __future__ import annotations

from typing import Any, Literal

from pydantic import BaseModel, Field

DiffKind = Literal["fill", "conflict", "enrichment", "agreement", "absent"]


class SourceKey(BaseModel):
    source: str
    key: str


class SourceVersion(BaseModel):
    source: str
    dump_date: str
    normalizer_version: int
    pipeline_version: int
    matcher_version: int | None = None


class RedirectInfo(BaseModel):
    redirected_from: list[SourceKey] = Field(default_factory=list)


class Envelope[T](BaseModel):
    source_version: SourceVersion
    data: T


class DiffEntry(BaseModel):
    field: str
    ours: Any = None
    theirs: Any = None
    kind: DiffKind


def _empty(value) -> bool:
    return value is None or value == "" or value == [] or value == {}


def classify_diff(ours, theirs) -> DiffKind:
    """Separate what is safe to apply in bulk from what needs judgement.

    Most results will be FILLS: books_editions has 3 rows with a language and 2
    with a page count, there are 19 credits in total, and book_relationships is
    empty. Separating fills from conflicts is what makes a 126k pass tractable
    rather than 126k manual reviews.

    Agreement means both sides are populated and equal. Absent means OL has
    nothing for this field.
    """
    if _empty(theirs):
        return "absent"
    if _empty(ours):
        return "fill"
    if isinstance(ours, list) and isinstance(theirs, list):
        if set(map(str, ours)) == set(map(str, theirs)):
            return "agreement"
        if set(map(str, ours)) < set(map(str, theirs)):
            return "enrichment"
        return "conflict"
    return "agreement" if ours == theirs else "conflict"
