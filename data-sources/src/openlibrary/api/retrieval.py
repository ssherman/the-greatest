"""Retrieval endpoints: the five GETs an agent reaches for on day one.

    GET /works/{work_key}              full work record
    GET /works/{work_key}/editions      language, pages, publisher, year, ISBNs, binding
    GET /authors/{author_key}
    GET /authors/{author_key}/works     the shelf -- paginated, popularity-ordered
    GET /identifiers/{type}/{value}     -> work(s), always a LIST

REDIRECT TRANSPARENCY (see common.schemas): a merged key returns the terminal
record plus `redirected_from`, so the 9.9% stale keys resolve instead of
404ing. `redirects` is already transitive (Task 30 built it that way), so a
requested key resolves to its terminal in exactly one join -- there is no
chain-walking here.

ONE QUERY PATH (ruling R71): `fetch_works` and `fetch_authors` are set-based --
they take a list of keys and return a dict keyed by the REQUESTED key, `None`
for a key that does not resolve to a real record. The singular endpoints below
call them with a list of one. Task 32's batch endpoints will call the same
functions with up to 500; there is deliberately no second lookup path.
`resolve_work_key` is the one-key convenience over the same resolver.

Every query in this module runs on the request's own cursor
(`deps.cursor(state)`), never on `state.connection` -- see `deps.py`. Scratch
tables loaded via `pipeline.duck.load_rows` are TEMP (R82), so cursors from
concurrent requests cannot collide on a shared scratch-table name.
"""

from __future__ import annotations

from typing import Literal

import duckdb
from fastapi import APIRouter, Depends, HTTPException, Path, Query
from pydantic import BaseModel, Field

from common.normalize import (
    IDENTIFIER_TYPES,
    normalize_asin,
    normalize_goodreads,
    normalize_isbn,
    normalize_lccn,
    normalize_oclc,
)
from common.schemas import Envelope, SourceKey
from openlibrary.api.deps import ArtifactState, cursor, get_state
from openlibrary.pipeline.duck import load_rows
from openlibrary.pipeline.paths import ArtifactPaths

router = APIRouter()

SOURCE = "openlibrary"

WORK_KEY_PATTERN = r"^OL\d+W$"
AUTHOR_KEY_PATTERN = r"^OL\d+A$"


def _key(key: str) -> SourceKey:
    return SourceKey(source=SOURCE, key=key)


# --------------------------------------------------------------------------- models


class AuthorRef(BaseModel):
    key: SourceKey
    name: str


class YearEvidence(BaseModel):
    declared_year: int | None = None
    min_edition_year: int | None = None
    second_min_edition_year: int | None = None
    modal_edition_year: int | None = None
    modal_edition_year_count: int | None = None
    edition_year_count: int | None = None
    edition_count: int | None = None


class Popularity(BaseModel):
    edition_count: int | None = None
    readinglog_count: int | None = None
    ratings_count: int | None = None
    ratings_avg: float | None = None


class WorkRecord(BaseModel):
    key: SourceKey
    redirected_from: list[SourceKey] = Field(default_factory=list)
    title: str | None = None
    subtitle: str | None = None
    description: str | None = None
    authors: list[AuthorRef] = Field(default_factory=list)
    subjects: list[str] = Field(default_factory=list)
    year_evidence: YearEvidence | None = None
    popularity: Popularity | None = None


class EditionRecord(BaseModel):
    key: SourceKey
    title: str | None = None
    subtitle: str | None = None
    publish_year: int | None = None
    publish_date_raw: str | None = None
    language_code: str | None = None
    page_count: int | None = None
    publisher: str | None = None
    physical_format: str | None = None
    edition_name: str | None = None
    series: list[str] = Field(default_factory=list)
    isbn13: list[str] = Field(default_factory=list)
    isbn10: list[str] = Field(default_factory=list)
    oclc: list[str] = Field(default_factory=list)
    lccn: list[str] = Field(default_factory=list)
    asin: list[str] = Field(default_factory=list)
    goodreads: list[str] = Field(default_factory=list)


class AuthorRecord(BaseModel):
    key: SourceKey
    redirected_from: list[SourceKey] = Field(default_factory=list)
    name: str | None = None
    alternate_names: list[str] = Field(default_factory=list)
    birth_year: int | None = None
    death_year: int | None = None


class ShelfEntry(BaseModel):
    key: SourceKey
    title: str | None = None
    readinglog_count: int
    edition_count: int
    ratings_count: int
    declared_year: int | None = None


class IdentifierHit(BaseModel):
    work: SourceKey
    redirected_from: list[SourceKey] = Field(default_factory=list)
    editions: list[SourceKey] = Field(default_factory=list)
    id_type: str
    value: str


# ------------------------------------------------------------------------ resolution


def _resolve_terminals(
    cur: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    keys: list[str],
    *,
    entity: str,
) -> dict[str, str]:
    """requested key -> terminal key, via one non-cycle non-dangling redirect
    hop (`redirects` is already transitive -- Task 30). A key with no
    redirect row maps to itself."""
    wanted = list(dict.fromkeys(k for k in keys if k))
    if not wanted:
        return {}
    load_rows(cur, "req_keys", [("requested", "VARCHAR")], [(k,) for k in wanted])
    rows = cur.execute(
        f"""
        SELECT k.requested, COALESCE(r.terminal_key, k.requested) AS terminal
        FROM req_keys k
        LEFT JOIN '{paths.table("redirects")}' r
          ON r.source_key = k.requested AND r.entity = ? AND NOT r.is_cycle AND NOT r.is_dangling
        """,
        [entity],
    ).fetchall()
    return {requested: terminal for requested, terminal in rows}


# --------------------------------------------------------------------------- works


def fetch_works(
    cur: duckdb.DuckDBPyConnection, paths: ArtifactPaths, keys: list[str]
) -> dict[str, WorkRecord | None]:
    """Set-based work fetch, keyed by the REQUESTED key (ruling R71).

    A requested key whose terminal is not in `works` maps to None. A
    requested key that differs from its terminal carries `redirected_from`.
    """
    requested_keys = list(dict.fromkeys(k for k in keys if k))
    if not requested_keys:
        return {}

    terminal_by_requested = _resolve_terminals(cur, paths, requested_keys, entity="work")
    terminals = list(dict.fromkeys(terminal_by_requested.values()))
    load_rows(cur, "term_work_keys", [("terminal", "VARCHAR")], [(t,) for t in terminals])

    base_rows = cur.execute(
        f"""
        SELECT w.work_key, w.title, wd.subtitle, wd.description, wd.subjects
        FROM term_work_keys t
        JOIN '{paths.table("works")}' w ON w.work_key = t.terminal
        LEFT JOIN '{paths.table("work_details")}' wd ON wd.work_key = w.work_key
        """
    ).fetchall()
    base_by_key: dict[str, tuple] = {row[0]: row for row in base_rows}

    year_evidence_by_key: dict[str, YearEvidence] = {}
    for row in cur.execute(
        f"""
        SELECT ye.work_key, ye.declared_year, ye.min_edition_year, ye.second_min_edition_year,
               ye.modal_edition_year, ye.modal_edition_year_count, ye.edition_year_count,
               ye.edition_count
        FROM term_work_keys t
        JOIN '{paths.table("year_evidence")}' ye ON ye.work_key = t.terminal
        """
    ).fetchall():
        (work_key, *fields) = row
        year_evidence_by_key[work_key] = YearEvidence(
            declared_year=fields[0],
            min_edition_year=fields[1],
            second_min_edition_year=fields[2],
            modal_edition_year=fields[3],
            modal_edition_year_count=fields[4],
            edition_year_count=fields[5],
            edition_count=fields[6],
        )

    popularity_by_key: dict[str, Popularity] = {}
    for row in cur.execute(
        f"""
        SELECT p.work_key, p.edition_count, p.readinglog_count, p.ratings_count, p.ratings_avg
        FROM term_work_keys t
        JOIN '{paths.table("popularity")}' p ON p.work_key = t.terminal
        """
    ).fetchall():
        work_key, edition_count, readinglog_count, ratings_count, ratings_avg = row
        popularity_by_key[work_key] = Popularity(
            edition_count=edition_count,
            readinglog_count=readinglog_count,
            ratings_count=ratings_count,
            ratings_avg=ratings_avg,
        )

    authors_by_key: dict[str, list[AuthorRef]] = {}
    for work_key, author_key, name, _position in cur.execute(
        f"""
        SELECT wa.work_key, a.author_key, a.name, wa.position
        FROM term_work_keys t
        JOIN '{paths.table("work_authors")}' wa ON wa.work_key = t.terminal
        JOIN '{paths.table("authors")}' a ON a.author_key = wa.author_key
        ORDER BY wa.work_key, wa.position
        """
    ).fetchall():
        authors_by_key.setdefault(work_key, []).append(AuthorRef(key=_key(author_key), name=name))

    results: dict[str, WorkRecord | None] = {}
    for requested in requested_keys:
        terminal = terminal_by_requested[requested]
        base = base_by_key.get(terminal)
        if base is None:
            results[requested] = None
            continue
        _, title, subtitle, description, subjects = base
        results[requested] = WorkRecord(
            key=_key(terminal),
            redirected_from=[_key(requested)] if requested != terminal else [],
            title=title,
            subtitle=subtitle,
            description=description,
            authors=authors_by_key.get(terminal, []),
            subjects=list(subjects or []),
            year_evidence=year_evidence_by_key.get(terminal),
            popularity=popularity_by_key.get(terminal),
        )
    return results


def resolve_work_key(
    cur: duckdb.DuckDBPyConnection, paths: ArtifactPaths, key: str
) -> tuple[str | None, list[str]]:
    """The one-key convenience over `fetch_works`'s resolver: terminal key (or
    None if the key does not resolve to a real work) plus the chain it came
    from (`[key]` if redirected, else `[]`)."""
    record = fetch_works(cur, paths, [key]).get(key)
    if record is None:
        return None, []
    return record.key.key, [rf.key for rf in record.redirected_from]


# -------------------------------------------------------------------------- authors


def fetch_authors(
    cur: duckdb.DuckDBPyConnection, paths: ArtifactPaths, keys: list[str]
) -> dict[str, AuthorRecord | None]:
    """Set-based author fetch, keyed by the REQUESTED key. Same shape as
    `fetch_works` (ruling R71)."""
    requested_keys = list(dict.fromkeys(k for k in keys if k))
    if not requested_keys:
        return {}

    terminal_by_requested = _resolve_terminals(cur, paths, requested_keys, entity="author")
    terminals = list(dict.fromkeys(terminal_by_requested.values()))
    load_rows(cur, "term_author_keys", [("terminal", "VARCHAR")], [(t,) for t in terminals])

    base_rows = cur.execute(
        f"""
        SELECT a.author_key, a.name, a.birth_year, a.death_year
        FROM term_author_keys t
        JOIN '{paths.table("authors")}' a ON a.author_key = t.terminal
        """
    ).fetchall()
    base_by_key = {row[0]: row for row in base_rows}

    alternates_by_key: dict[str, list[str]] = {}
    for author_key, name in cur.execute(
        f"""
        SELECT an.author_key, an.name
        FROM term_author_keys t
        JOIN '{paths.table("author_names")}' an ON an.author_key = t.terminal
        WHERE an.source = 'alternate'
        ORDER BY an.author_key, an.name
        """
    ).fetchall():
        alternates_by_key.setdefault(author_key, []).append(name)

    results: dict[str, AuthorRecord | None] = {}
    for requested in requested_keys:
        terminal = terminal_by_requested[requested]
        base = base_by_key.get(terminal)
        if base is None:
            results[requested] = None
            continue
        _, name, birth_year, death_year = base
        results[requested] = AuthorRecord(
            key=_key(terminal),
            redirected_from=[_key(requested)] if requested != terminal else [],
            name=name,
            alternate_names=alternates_by_key.get(terminal, []),
            birth_year=birth_year,
            death_year=death_year,
        )
    return results


# ------------------------------------------------------------------------- editions


def _fetch_editions_for_terminal(
    cur: duckdb.DuckDBPyConnection, paths: ArtifactPaths, terminal: str
) -> list[EditionRecord]:
    """R83: editions filed under a key that has since merged into `terminal`
    still reach it -- `redirects` is queried for every source key whose
    terminal is this one."""
    edition_rows = cur.execute(
        f"""
        SELECT edition_key, title, subtitle, publish_year, publish_date_raw, language_code,
               page_count, publisher, physical_format, edition_name, series
        FROM '{paths.table("editions")}'
        WHERE work_key = ?
           OR work_key IN (
             SELECT source_key FROM '{paths.table("redirects")}'
             WHERE terminal_key = ? AND entity = 'work' AND NOT is_cycle
           )
        ORDER BY publish_year NULLS LAST, edition_key
        """,
        [terminal, terminal],
    ).fetchall()
    if not edition_rows:
        return []

    edition_keys = [row[0] for row in edition_rows]
    load_rows(cur, "req_edition_keys", [("edition_key", "VARCHAR")], [(k,) for k in edition_keys])
    identifiers_by_edition: dict[str, dict[str, set[str]]] = {}
    for edition_key, id_type, value in cur.execute(
        f"""
        SELECT i.edition_key, i.id_type, i.value
        FROM '{paths.table("identifiers")}' i
        JOIN req_edition_keys k USING (edition_key)
        """
    ).fetchall():
        identifiers_by_edition.setdefault(edition_key, {}).setdefault(id_type, set()).add(value)

    records = []
    for row in edition_rows:
        (
            edition_key,
            title,
            subtitle,
            publish_year,
            publish_date_raw,
            language_code,
            page_count,
            publisher,
            physical_format,
            edition_name,
            series,
        ) = row
        ids = identifiers_by_edition.get(edition_key, {})
        records.append(
            EditionRecord(
                key=_key(edition_key),
                title=title,
                subtitle=subtitle,
                publish_year=publish_year,
                publish_date_raw=publish_date_raw,
                language_code=language_code,
                page_count=page_count,
                publisher=publisher,
                physical_format=physical_format,
                edition_name=edition_name,
                series=list(series or []),
                isbn13=sorted(ids.get("isbn13", ())),
                isbn10=sorted(ids.get("isbn10", ())),
                oclc=sorted(ids.get("oclc", ())),
                lccn=sorted(ids.get("lccn", ())),
                asin=sorted(ids.get("asin", ())),
                goodreads=sorted(ids.get("goodreads", ())),
            )
        )
    return records


# --------------------------------------------------------------------------- shelf


def _fetch_shelf(
    cur: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    author_terminal: str,
    *,
    limit: int,
    offset: int,
) -> list[ShelfEntry]:
    rows = cur.execute(
        f"""
        SELECT w.work_key, w.title,
               COALESCE(p.readinglog_count, 0) AS readinglog_count,
               COALESCE(p.edition_count, 0) AS edition_count,
               COALESCE(p.ratings_count, 0) AS ratings_count,
               wd.declared_year
        FROM '{paths.table("work_authors")}' wa
        JOIN '{paths.table("works")}' w ON w.work_key = wa.work_key
        LEFT JOIN '{paths.table("popularity")}' p ON p.work_key = wa.work_key
        LEFT JOIN '{paths.table("work_details")}' wd ON wd.work_key = wa.work_key
        WHERE wa.author_key = ?
        ORDER BY readinglog_count DESC, edition_count DESC, w.work_key
        LIMIT ? OFFSET ?
        """,
        [author_terminal, limit, offset],
    ).fetchall()
    return [
        ShelfEntry(
            key=_key(work_key),
            title=title,
            readinglog_count=readinglog_count,
            edition_count=edition_count,
            ratings_count=ratings_count,
            declared_year=declared_year,
        )
        for work_key, title, readinglog_count, edition_count, ratings_count, declared_year in rows
    ]


# ----------------------------------------------------------------------- identifiers


_NORMALIZERS = {
    "oclc": normalize_oclc,
    "lccn": normalize_lccn,
    "asin": normalize_asin,
    "goodreads": normalize_goodreads,
}


def _normalize_identifier_value(id_type: str, value: str) -> str | None:
    if id_type in ("isbn13", "isbn10"):
        normalized = normalize_isbn(value)
        if normalized is None:
            return None
        return normalized.isbn13 if id_type == "isbn13" else normalized.isbn10
    return _NORMALIZERS[id_type](value)


def _fetch_identifier_hits(
    cur: duckdb.DuckDBPyConnection, paths: ArtifactPaths, id_type: str, value: str
) -> list[IdentifierHit]:
    """R83: resolve `identifiers.work_key` through redirects (COALESCE to
    terminal), drop rows whose terminal is not in `works`, and return one
    `IdentifierHit` per distinct terminal work, ordered by work key."""
    rows = cur.execute(
        f"""
        WITH matched AS (
          SELECT i.edition_key, i.work_key AS requested_work,
                 COALESCE(r.terminal_key, i.work_key) AS terminal
          FROM '{paths.table("identifiers")}' i
          LEFT JOIN '{paths.table("redirects")}' r
            ON r.source_key = i.work_key AND r.entity = 'work'
               AND NOT r.is_cycle AND NOT r.is_dangling
          WHERE i.id_type = ? AND i.value = ? AND i.work_key IS NOT NULL
        )
        SELECT m.terminal, m.requested_work, m.edition_key
        FROM matched m
        JOIN '{paths.table("works")}' w ON w.work_key = m.terminal
        """,
        [id_type, value],
    ).fetchall()

    by_terminal: dict[str, dict[str, set[str]]] = {}
    for terminal, requested_work, edition_key in rows:
        bucket = by_terminal.setdefault(terminal, {"redirected_from": set(), "editions": set()})
        if requested_work != terminal:
            bucket["redirected_from"].add(requested_work)
        if edition_key:
            bucket["editions"].add(edition_key)

    return [
        IdentifierHit(
            work=_key(terminal),
            redirected_from=[_key(k) for k in sorted(bucket["redirected_from"])],
            editions=[_key(k) for k in sorted(bucket["editions"])],
            id_type=id_type,
            value=value,
        )
        for terminal, bucket in sorted(by_terminal.items())
    ]


# ----------------------------------------------------------------------------- routes


@router.get("/works/{work_key}", response_model=Envelope[WorkRecord])
def get_work(
    work_key: str = Path(pattern=WORK_KEY_PATTERN),
    state: ArtifactState = Depends(get_state),
):
    with cursor(state) as cur:
        record = fetch_works(cur, state.paths, [work_key])[work_key]
    if record is None:
        raise HTTPException(status_code=404, detail=f"unknown work: {work_key}")
    return Envelope(source_version=state.source_version, data=record)


@router.get("/works/{work_key}/editions", response_model=Envelope[list[EditionRecord]])
def get_work_editions(
    work_key: str = Path(pattern=WORK_KEY_PATTERN),
    state: ArtifactState = Depends(get_state),
):
    with cursor(state) as cur:
        terminal, _chain = resolve_work_key(cur, state.paths, work_key)
        if terminal is None:
            raise HTTPException(status_code=404, detail=f"unknown work: {work_key}")
        editions = _fetch_editions_for_terminal(cur, state.paths, terminal)
    return Envelope(source_version=state.source_version, data=editions)


@router.get("/authors/{author_key}", response_model=Envelope[AuthorRecord])
def get_author(
    author_key: str = Path(pattern=AUTHOR_KEY_PATTERN),
    state: ArtifactState = Depends(get_state),
):
    with cursor(state) as cur:
        record = fetch_authors(cur, state.paths, [author_key])[author_key]
    if record is None:
        raise HTTPException(status_code=404, detail=f"unknown author: {author_key}")
    return Envelope(source_version=state.source_version, data=record)


@router.get("/authors/{author_key}/works", response_model=Envelope[list[ShelfEntry]])
def get_author_works(
    author_key: str = Path(pattern=AUTHOR_KEY_PATTERN),
    limit: int = Query(50, ge=1, le=500),
    offset: int = Query(0, ge=0),
    state: ArtifactState = Depends(get_state),
):
    with cursor(state) as cur:
        record = fetch_authors(cur, state.paths, [author_key])[author_key]
        if record is None:
            raise HTTPException(status_code=404, detail=f"unknown author: {author_key}")
        shelf = _fetch_shelf(cur, state.paths, record.key.key, limit=limit, offset=offset)
    return Envelope(source_version=state.source_version, data=shelf)


@router.get("/identifiers/{id_type}/{value}", response_model=Envelope[list[IdentifierHit]])
def get_identifier(
    id_type: Literal[IDENTIFIER_TYPES],
    value: str,
    state: ArtifactState = Depends(get_state),
):
    normalized = _normalize_identifier_value(id_type, value)
    if normalized is None:
        raise HTTPException(
            status_code=422, detail=f"{value!r} is not a valid {id_type} identifier"
        )
    with cursor(state) as cur:
        hits = _fetch_identifier_hits(cur, state.paths, id_type, normalized)
    return Envelope(source_version=state.source_version, data=hits)
