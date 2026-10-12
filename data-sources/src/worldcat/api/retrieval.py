"""Exact lookups. Routes are sync `def` on purpose: DuckDB blocks, and FastAPI
runs sync routes in its threadpool."""

import duckdb
from fastapi import APIRouter, Depends, HTTPException

from common.normalize import normalize_isbn
from openlibrary.api.limits import Deadline
from worldcat.api.deps import ArtifactState, cursor, get_state
from worldcat.api.schemas import Holdings, IsbnResponse, LookupRequest, LookupResponse, Record
from worldcat.pipeline.paths import WorldcatPaths

router = APIRouter()
MAX_BATCH = 500
RECORD_COLUMNS = (
    "oclc",
    "title",
    "subtitle",
    "creator",
    "contributors",
    "year",
    "publication_date_raw",
    "publisher",
    "publication_place",
    "cataloging_language",
    "specific_format",
    "edition_statement",
    "physical_description",
    "series",
    "genre",
    "subjects",
    "isbn13s",
    "merged_oclc",
    "other_format_oclc",
    "total_editions",
    "summary",
    "source_type",
)


def fetch_records(
    cur: duckdb.DuckDBPyConnection, paths: WorldcatPaths, oclcs: list[int]
) -> dict[int, Record]:
    if not oclcs:
        return {}
    placeholders = ", ".join("?" for _ in oclcs)
    columns = ", ".join(f"r.{c}" for c in RECORD_COLUMNS)
    rows = cur.execute(
        f"SELECT {columns}, h.total_holding_count, h.total_editions AS holdings_editions "
        f"FROM '{paths.table('records')}' r "
        f"LEFT JOIN '{paths.table('holdings')}' h USING (oclc) "
        f"WHERE r.oclc IN ({placeholders})",
        oclcs,
    ).fetchall()
    out: dict[int, Record] = {}
    for row in rows:
        data = dict(zip(RECORD_COLUMNS, row[: len(RECORD_COLUMNS)], strict=True))
        for key in ("contributors", "subjects", "isbn13s", "merged_oclc", "other_format_oclc"):
            data[key] = data[key] or []
        holding_count, holding_editions = row[len(RECORD_COLUMNS) :]
        if holding_count is not None:
            data["holdings"] = Holdings(
                total_holding_count=holding_count, total_editions=holding_editions
            )
        out[data["oclc"]] = Record(**data)
    return out


def resolve_oclc(
    cur: duckdb.DuckDBPyConnection, paths: WorldcatPaths, number: int
) -> tuple[int | None, int | None]:
    """(current number, redirected_from). A number with no redirect is its own current number.
    A cycle (or a chain past the hop limit) resolves to nothing: (None, None). Records and
    redirects are distilled independently, so a cycle source can still own a stale record;
    returning None keeps the route from serving it."""
    row = cur.execute(
        f"SELECT to_oclc, is_cycle FROM '{paths.table('redirects')}' WHERE from_oclc = ?",
        [number],
    ).fetchone()
    if row is None:
        return number, None
    if row[1]:
        return None, None
    return row[0], number


def _isbn13_or_422(value: str) -> str:
    normalized = normalize_isbn(value)
    if normalized is None or not normalized.checksum_ok or not normalized.isbn13:
        raise HTTPException(status_code=422, detail=f"{value!r} is not a valid ISBN")
    return normalized.isbn13


def _records_for_isbn13s(
    cur: duckdb.DuckDBPyConnection, paths: WorldcatPaths, isbn13s: list[str]
) -> dict[str, list[Record]]:
    if not isbn13s:
        return {}
    placeholders = ", ".join("?" for _ in isbn13s)
    pairs = cur.execute(
        f"SELECT isbn13, oclc FROM '{paths.table('isbns')}' WHERE isbn13 IN ({placeholders})",
        isbn13s,
    ).fetchall()
    records = fetch_records(cur, paths, sorted({oclc for _, oclc in pairs}))
    out: dict[str, list[Record]] = {isbn: [] for isbn in isbn13s}
    for isbn13, oclc in pairs:
        if oclc in records:
            out[isbn13].append(records[oclc])
    return out


def _with_deadline(state: ArtifactState, fn):
    with cursor(state) as cur, Deadline(cur, state.deadline_s) as deadline:
        try:
            return fn(cur)
        except duckdb.InterruptException:
            if not deadline.expired:
                raise
            raise HTTPException(
                status_code=504, detail=f"deadline: lookup stopped after {state.deadline_s:g} s"
            ) from None


@router.get("/isbns/{isbn}", response_model=IsbnResponse)
def get_isbn(isbn: str, state: ArtifactState = Depends(get_state)):
    isbn13 = _isbn13_or_422(isbn)
    records = _with_deadline(state, lambda cur: _records_for_isbn13s(cur, state.paths, [isbn13]))
    return IsbnResponse(isbn13=isbn13, records=records.get(isbn13, []))


@router.get("/oclc/{number}", response_model=Record)
def get_oclc(number: int, state: ArtifactState = Depends(get_state)):
    def run(cur):
        current, redirected_from = resolve_oclc(cur, state.paths, number)
        record = fetch_records(cur, state.paths, [current]).get(current) if current else None
        if record is None:
            raise HTTPException(status_code=404, detail=f"unknown OCLC number: {number}")
        return record.model_copy(update={"redirected_from": redirected_from})

    return _with_deadline(state, run)


@router.post("/lookup", response_model=LookupResponse)
def post_lookup(request: LookupRequest, state: ArtifactState = Depends(get_state)):
    if len(request.isbn13s) > MAX_BATCH:
        raise HTTPException(status_code=422, detail=f"at most {MAX_BATCH} ISBNs per request")
    normalized: dict[str, str] = {}
    bad = []
    for value in request.isbn13s:
        parsed = normalize_isbn(value)
        if parsed is None or not parsed.checksum_ok or not parsed.isbn13:
            bad.append(value)
        else:
            normalized[value] = parsed.isbn13
    if bad:
        raise HTTPException(status_code=422, detail=f"invalid ISBN(s): {bad}")
    found = _with_deadline(
        state, lambda cur: _records_for_isbn13s(cur, state.paths, sorted(set(normalized.values())))
    )
    return LookupResponse(
        results={value: found.get(isbn13, []) for value, isbn13 in normalized.items()}
    )
