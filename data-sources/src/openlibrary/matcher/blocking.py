"""Stage 1: generate candidates. Never decides anything.

Six rules, UNIONED. Measured on 122,970 usable books:

    title-fp only   >=1: 82.2%   unique: 26.5%   median 3   p90 42   max 6,124
    author-blocked  >=1: 63.4%   unique: 38.0%   median 1   p90 4    max 407
    UNION           >=1: 82.2%          exactly one: 44.6%

So author blocking is a PRECISION rule and title blocking is a RECALL rule.
Neither gates the other; an author-resolution failure costs rules 3 and 5 and
leaves 1, 4 and 6 firing.

Every rule has a volume guard. A rule that would return too much does not fire
and says so: a visible gap beats a query that never returns.
"""

from __future__ import annotations

import duckdb
from pydantic import BaseModel, Field

from common.normalize import (
    MIN_BLOCKING_FP_LENGTH,
    fingerprint,
    identifier_pairs,
    title_fingerprints,
)
from openlibrary.pipeline.duck import load_rows
from openlibrary.pipeline.paths import ArtifactPaths

RULES = (
    "identifier",
    "existing_key",
    "author_title_fp",
    "title_fp",
    "author_shelf",
    "trigram",
)

MAX_CANDIDATES_PER_RULE = 200
MAX_TITLE_FP_FREQ = 50
MAX_SHELF_SIZE = 500
TRIGRAM_MIN_SIMILARITY = 0.55


class BlockingQuery(BaseModel):
    title: str
    subtitle: str | None = None
    author_names: list[str] = Field(default_factory=list)
    year: int | None = None
    language: str | None = None
    isbn13: list[str] = Field(default_factory=list)
    isbn10: list[str] = Field(default_factory=list)
    asin: list[str] = Field(default_factory=list)
    goodreads_id: list[str] = Field(default_factory=list)  # [GOODREADS]
    oclc: list[str] = Field(default_factory=list)
    lccn: list[str] = Field(default_factory=list)
    existing_ol_key: str | None = None


class BlockingResult(BaseModel):
    candidates: dict[str, list[str]] = Field(default_factory=dict)
    guards_tripped: list[str] = Field(default_factory=list)


def _add(result: BlockingResult, work_key: str, rule: str) -> None:
    rules = result.candidates.setdefault(work_key, [])
    if rule not in rules:
        rules.append(rule)


def generate_candidates(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    query: BlockingQuery,
) -> BlockingResult:
    result = BlockingResult()
    fps = title_fingerprints(query.title)
    variants = [fp for fp in {fps.full, fps.nosub, fps.noart} if len(fp) >= MIN_BLOCKING_FP_LENGTH]
    author_fps = [fp for fp in (fingerprint(n) for n in query.author_names) if fp]

    # Rule 1 -- identifiers. Deterministic; may legitimately return several works.
    identifiers = identifier_pairs(
        isbn13=query.isbn13,
        isbn10=query.isbn10,
        asin=query.asin,
        goodreads_id=query.goodreads_id,
        oclc=query.oclc,
        lccn=query.lccn,
    )
    if identifiers:
        load_rows(con, "q_ids", [("id_type", "VARCHAR"), ("value", "VARCHAR")], identifiers)
        rows = con.execute(
            f"""
            SELECT DISTINCT i.work_key FROM '{paths.table("identifiers")}' i
            JOIN q_ids q ON q.id_type = i.id_type AND q.value = i.value
            WHERE i.work_key IS NOT NULL
            LIMIT {MAX_CANDIDATES_PER_RULE + 1}
            """
        ).fetchall()
        if len(rows) > MAX_CANDIDATES_PER_RULE:
            result.guards_tripped.append("identifier")
        else:
            for (work_key,) in rows:
                _add(result, work_key, "identifier")

    # Rule 2 -- the stored OL key, redirect-resolved. A HINT, weighted like any
    # other evidence: 9.9% are dead and 380 are attached to several books.
    if query.existing_ol_key:
        row = con.execute(
            f"""
            SELECT COALESCE(r.terminal_key, ?) FROM (SELECT 1) t
            LEFT JOIN '{paths.table("redirects")}' r
              ON r.source_key = ? AND r.entity = 'work' AND NOT r.is_cycle
            """,
            [query.existing_ol_key, query.existing_ol_key],
        ).fetchone()
        if row and row[0]:
            (exists,) = con.execute(
                f"SELECT count(*) FROM '{paths.table('works')}' WHERE work_key = ?", [row[0]]
            ).fetchone()
            if exists:
                _add(result, row[0], "existing_key")

    # Rule 3 -- resolved author + any title fingerprint variant. Measured p90 = 4.
    if author_fps and variants:
        load_rows(con, "q_author_fps", [("name_fp", "VARCHAR")], [(fp,) for fp in author_fps])
        load_rows(con, "q_title_fps", [("title_fp", "VARCHAR")], [(fp,) for fp in variants])
        rows = con.execute(
            f"""
            SELECT DISTINCT w.work_key
            FROM '{paths.table("author_names")}' an
            JOIN q_author_fps q USING (name_fp)
            JOIN '{paths.table("work_authors")}' wa ON wa.author_key = an.author_key
            JOIN '{paths.table("works")}' w ON w.work_key = wa.work_key
            WHERE w.title_fp       IN (SELECT title_fp FROM q_title_fps)
               OR w.title_fp_nosub IN (SELECT title_fp FROM q_title_fps)
               OR w.title_fp_noart IN (SELECT title_fp FROM q_title_fps)
            LIMIT {MAX_CANDIDATES_PER_RULE + 1}
            """
        ).fetchall()
        if len(rows) > MAX_CANDIDATES_PER_RULE:
            result.guards_tripped.append("author_title_fp")
        else:
            for (work_key,) in rows:
                _add(result, work_key, "author_title_fp")

    # Rule 4 -- title fingerprint alone. The frequency guard is VISIBLE
    # (ruling R32): the query returns rows regardless of frequency, ordered
    # so legitimate rows (<= MAX_TITLE_FP_FREQ per variant, so <= 150 total
    # across the three variants) always sort ahead of a suppressed common
    # title and fit under the LIMIT. Python decides admission per row and
    # whether to record the guard from what came back. This is the
    # data-driven fix for the 604,144-row explosion, and it also catches
    # "selected poems" and "collected works", which pass any length check.
    #
    # `guards_tripped` may carry "title_fp" for two different reasons: an
    # empty/too-short fingerprint (the `else` branch below, e.g. "!!!") or a
    # common title suppressed here. No downstream code distinguishes between
    # them today.
    if variants:
        load_rows(con, "q_title_fps4", [("title_fp", "VARCHAR")], [(fp,) for fp in variants])
        rows = con.execute(
            f"""
            SELECT DISTINCT w.work_key, w.title_fp_freq FROM '{paths.table("works")}' w
            JOIN q_title_fps4 q ON q.title_fp = w.title_fp
            ORDER BY w.title_fp_freq
            LIMIT {MAX_CANDIDATES_PER_RULE + 1}
            """
        ).fetchall()
        if any(freq > MAX_TITLE_FP_FREQ for _, freq in rows) or len(rows) > MAX_CANDIDATES_PER_RULE:
            result.guards_tripped.append("title_fp")
        for work_key, freq in rows:
            if freq <= MAX_TITLE_FP_FREQ:
                _add(result, work_key, "title_fp")
    else:
        result.guards_tripped.append("title_fp")

    # Rule 5 -- the author's whole shelf. Once an author resolves, no search is
    # needed: fetch 5-500 works and let the scorer read every title.
    if author_fps:
        load_rows(con, "q_author_fps5", [("name_fp", "VARCHAR")], [(fp,) for fp in author_fps])
        rows = con.execute(
            f"""
            SELECT DISTINCT wa.work_key
            FROM '{paths.table("author_names")}' an
            JOIN q_author_fps5 q USING (name_fp)
            JOIN '{paths.table("work_authors")}' wa ON wa.author_key = an.author_key
            LIMIT {MAX_SHELF_SIZE + 1}
            """
        ).fetchall()
        if len(rows) > MAX_SHELF_SIZE:
            result.guards_tripped.append("author_shelf")
        else:
            for (work_key,) in rows[:MAX_CANDIDATES_PER_RULE]:
                _add(result, work_key, "author_shelf")

    # Rule 6 -- trigram fallback, ONLY for the ~18% with no exact hit anywhere.
    # Fuzzy retrieval serves a fallback path, not a pillar; this is why the
    # design does not carry a search engine.
    if not result.candidates and fps.full:
        rows = con.execute(
            f"""
            SELECT work_key FROM '{paths.table("works")}'
            WHERE title_fp <> ''
              AND jaccard(title_fp, ?) >= {TRIGRAM_MIN_SIMILARITY}
            ORDER BY jaccard(title_fp, ?) DESC
            LIMIT {MAX_CANDIDATES_PER_RULE}
            """,
            [fps.full, fps.full],
        ).fetchall()
        for (work_key,) in rows:
            _add(result, work_key, "trigram")

    return result
