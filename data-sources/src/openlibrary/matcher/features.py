"""Stage 2 inputs: one feature vector per (query, candidate work) pair.

Every feature is asymmetric -- agreement is positive, absence is neutral, absence
is never negative -- because our local data is sparse by fact, not by chance:
1.004 authors per book, 0 relationships, 19 credits, 3 editions with a language.

Popularity is a PRIOR AND TIE-BREAKER, never identity.

Identifier agreement is a WORK-LEVEL claim, not an ISBN-set claim (ruling
R35). The obvious design -- "our isbn13 set and the work's isbn13 set both
non-empty and disjoint" -- was measured against the 370 labelled true matches
on the real artifact and rejected: it would mark 51 of them (13.8%) as
conflicts on their OWN labelled work, because Open Library holds other
editions' ISBNs but not ours. That is ABSENCE, which the first paragraph
above says is never negative. The evidence that actually means "this
identifier belongs to someone else" is blocking rule 1 (see
openlibrary.matcher.blocking): the set of works our identifiers reached.
`extract` and `conflicts` take that set as `identifier_hits` -- a set of work
keys, one per work blocking's identifier rule matched -- and compare it
against the single candidate work's own key: this work among the hits is
agreement, some other work among the hits is conflict, no hits at all is
absent.
"""

from __future__ import annotations

import math

import duckdb
from pydantic import BaseModel, Field

from common.normalize import fingerprint
from common.scoring import identifier_agreement, set_overlap, title_similarity, year_agreement
from openlibrary.matcher.blocking import BlockingQuery
from openlibrary.pipeline.duck import load_rows
from openlibrary.pipeline.paths import ArtifactPaths

FEATURES = (
    "title_similarity",
    "title_variant_exact",
    "subtitle_agreement",
    "author_overlap",
    "author_name_similarity",
    "year_agreement",
    "identifier_agreement",
    "language_agreement",
    "popularity_prior",
)


class WorkView(BaseModel):
    work_key: str
    title: str | None = None
    title_fp: str = ""
    title_fp_nosub: str = ""
    title_fp_noart: str = ""
    subtitle: str | None = None
    author_names: list[str] = Field(default_factory=list)
    declared_year: int | None = None
    min_edition_year: int | None = None
    modal_edition_year: int | None = None
    edition_count: int = 0
    readinglog_count: int = 0
    ratings_count: int = 0
    languages: set[str] = Field(default_factory=set)
    subjects: list[str] = Field(default_factory=list)
    title_fp_freq: int = 0


def extract(
    query: BlockingQuery,
    work: WorkView,
    *,
    identifier_hits: frozenset[str] = frozenset(),
) -> dict[str, float | None]:
    ours = fingerprint(query.title)
    variants = {work.title_fp, work.title_fp_nosub, work.title_fp_noart}

    # An empty title fingerprint is ABSENCE, not disagreement (ruling R40):
    # protects the 30 `degenerate_title` evaluation cases and the ~1.5% of
    # works whose title_fp is empty from scoring as if they disagreed on
    # title. When both sides carry a fingerprint but it differs, 0.0 for
    # title_variant_exact stands -- that IS disagreement between two present
    # values.
    title_score: float | None = None
    variant_score: float | None = None
    if ours and work.title_fp:
        title_score = title_similarity(ours, work.title_fp)
        variant_score = 1.0 if ours in variants else 0.0

    our_authors = {fingerprint(n) for n in query.author_names if fingerprint(n)}
    their_authors = {fingerprint(n) for n in work.author_names if fingerprint(n)}

    author_similarity: float | None = None
    if our_authors and their_authors:
        author_similarity = max(title_similarity(a, b) for a in our_authors for b in their_authors)

    subtitle_score: float | None = None
    if query.subtitle and work.subtitle:
        subtitle_score = title_similarity(fingerprint(query.subtitle), fingerprint(work.subtitle))

    # See the module docstring for the 51-of-370 measurement that ruled out
    # comparing ISBN sets directly. `theirs` is always the one-element set
    # {work.work_key}, so `identifier_agreement` reduces to: no hits at all
    # -> absent; this work is one of the hits -> agree; hits exist and point
    # elsewhere -> conflict.
    identifier_score: float | None = None
    agreement = identifier_agreement(ours=identifier_hits, theirs={work.work_key})
    if agreement == "agree":
        identifier_score = 1.0
    elif agreement == "conflict":
        identifier_score = 0.0

    language_score: float | None = None
    if query.language and work.languages:
        language_score = 1.0 if query.language in work.languages else 0.0

    # log1p keeps a 9,000-reader classic from swamping a 60-reader one by two
    # orders of magnitude. Bounded so it can only ever break a tie.
    signal = work.readinglog_count + work.ratings_count + work.edition_count
    popularity = math.log1p(signal) / math.log1p(100_000)

    return {
        "title_similarity": title_score,
        "title_variant_exact": variant_score,
        "subtitle_agreement": subtitle_score,
        "author_overlap": set_overlap(our_authors, their_authors),
        "author_name_similarity": author_similarity,
        "year_agreement": year_agreement(
            query.year,
            work.declared_year if work.declared_year is not None else work.min_edition_year,
            work.modal_edition_year
            if work.modal_edition_year is not None
            else work.min_edition_year,
        ),
        "identifier_agreement": identifier_score,
        "language_agreement": language_score,
        "popularity_prior": min(popularity, 1.0),
    }


def conflicts(
    query: BlockingQuery,
    work: WorkView,
    *,
    identifier_hits: frozenset[str] = frozenset(),
) -> list[str]:
    found = []
    if identifier_agreement(ours=identifier_hits, theirs={work.work_key}) == "conflict":
        found.append("identifier")
    return found


def load_work_views(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    work_keys: list[str],
) -> dict[str, WorkView]:
    """Assemble one `WorkView` per requested work key.

    Aggregates the two one-to-many sides (authors, edition languages) in
    their own subqueries rather than joining both into one GROUP BY (ruling
    R36): `work_authors` x `authors` x `editions` in a single join is
    authors-times-editions rows per work before dedup -- hundreds of
    thousands for a 400-edition classic, times up to 500 candidates now that
    blocking rule 5 admits a whole author shelf. Aggregating each side first
    keeps every join one-row-per-work.

    EVERY table this function touches is filtered down to `wanted_works`
    in its own CTE before it is joined to anything else -- including the
    nominally 1:1 tables (`works`, `work_details`, `year_evidence`,
    `popularity`), not only the two aggregates. Ruling R44 fixed the
    aggregates first (`work_authors`/`editions` are 44.7M/56.6M rows, and
    grouping either in full before filtering down OOM'd on the very first
    real-artifact call, ~43s, at any thread count). That alone was not
    enough: `works` and `work_details` are themselves ~41.5M/~41.4M rows,
    and joining `wanted_works` inline against the full parquet scan left
    DuckDB's join-order optimizer free to reorder the remaining LEFT JOINs
    -- confirmed via `EXPLAIN`, whose cardinality estimate for the final
    projection was ~41.5M rows, not 500, meaning it was choosing physical
    plans as if the filter barely narrowed anything, and building a hash
    table over one of the multi-million-row sides. Pre-filtering every
    relation via its own `wanted_works` CTE removes that choice entirely:
    every join the final SELECT performs is between relations DuckDB knows
    are already work_keys-sized, so there is no large side left for a bad
    estimate to pick.
    """
    if not work_keys:
        return {}
    load_rows(con, "wanted_works", [("work_key", "VARCHAR")], [(k,) for k in work_keys])
    rows = con.execute(
        f"""
        WITH filtered_works AS (
          SELECT w.* FROM wanted_works ww
          JOIN '{paths.table("works")}' w USING (work_key)
        ),
        filtered_details AS (
          SELECT d.* FROM wanted_works ww
          JOIN '{paths.table("work_details")}' d USING (work_key)
        ),
        filtered_year_evidence AS (
          SELECT y.* FROM wanted_works ww
          JOIN '{paths.table("year_evidence")}' y USING (work_key)
        ),
        filtered_popularity AS (
          SELECT p.* FROM wanted_works ww
          JOIN '{paths.table("popularity")}' p USING (work_key)
        ),
        agg_authors AS (
          SELECT wa.work_key, list(DISTINCT a.name ORDER BY a.name) AS author_names
          FROM wanted_works ww
          JOIN '{paths.table("work_authors")}' wa USING (work_key)
          JOIN '{paths.table("authors")}' a USING (author_key)
          WHERE a.name IS NOT NULL
          GROUP BY wa.work_key
        ),
        agg_languages AS (
          SELECT e.work_key, list(DISTINCT e.language_code ORDER BY e.language_code) AS languages
          FROM wanted_works ww
          JOIN '{paths.table("editions")}' e USING (work_key)
          WHERE e.language_code IS NOT NULL
          GROUP BY e.work_key
        )
        SELECT
          w.work_key, w.title, w.title_fp, w.title_fp_nosub, w.title_fp_noart,
          w.title_fp_freq,
          d.subtitle, d.declared_year, d.subjects,
          y.min_edition_year, y.modal_edition_year,
          COALESCE(p.edition_count, 0), COALESCE(p.readinglog_count, 0),
          COALESCE(p.ratings_count, 0),
          COALESCE(aa.author_names, []) AS author_names,
          COALESCE(al.languages, [])    AS languages
        FROM filtered_works w
        LEFT JOIN filtered_details d USING (work_key)
        LEFT JOIN filtered_year_evidence y USING (work_key)
        LEFT JOIN filtered_popularity p USING (work_key)
        LEFT JOIN agg_authors aa USING (work_key)
        LEFT JOIN agg_languages al USING (work_key)
        """
    ).fetchall()

    views = {}
    for row in rows:
        views[row[0]] = WorkView(
            work_key=row[0],
            title=row[1],
            title_fp=row[2] or "",
            title_fp_nosub=row[3] or "",
            title_fp_noart=row[4] or "",
            title_fp_freq=row[5] or 0,
            subtitle=row[6],
            declared_year=row[7],
            subjects=list(row[8] or []),
            min_edition_year=row[9],
            modal_edition_year=row[10],
            edition_count=row[11],
            readinglog_count=row[12],
            ratings_count=row[13],
            author_names=list(row[14] or []),
            languages=set(row[15] or []),
        )
    return views
