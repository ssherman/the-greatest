"""POST /resolve: candidates, evidence and a diff -- never a single answer.

The resolution half of the service. This is the harness's own per-case loop
(`eval.harness.prepare` + `evaluate`, read there first) run once per request,
on the request's own cursor: `generate_candidates` -> `identifier_hits` ->
`load_work_views` -> `score_candidate` for every key that has a view ->
`rank` -> `decide(..., volume_guards_tripped=...)`. The matcher's scratch
tables are TEMP and cursor-local (R82), so concurrent requests never collide.

R75: scoring and `decide` see EVERY candidate blocking produced; `limit`
(on `ResolveRequest`) only truncates the candidate list actually returned,
after ranking -- the decision can never depend on how many results the
caller asked to see.

R72: the diff is a WORK-level comparison built from one `retrieval.fetch_works`
call over the returned candidates (never a per-candidate query) -- see
`build_diff`. R90: that same record rides on each candidate as `record`, so
an accepted candidate needs no follow-up `GET /works/{key}`.
"""

from __future__ import annotations

from collections.abc import Callable
from typing import Literal

import duckdb
from fastapi import APIRouter, Depends
from pydantic import BaseModel, ConfigDict, Field

from common.normalize import fingerprint, name_fingerprint
from common.schemas import DiffEntry, DiffKind, Envelope, SourceKey, classify_diff
from openlibrary.api.deps import ArtifactState, cursor, get_state
from openlibrary.api.retrieval import WorkRecord, fetch_works
from openlibrary.matcher.blocking import BlockingQuery, generate_candidates
from openlibrary.matcher.decide import Decision, decide, rank
from openlibrary.matcher.features import load_work_views
from openlibrary.matcher.scorer import ScoredCandidate, Weights, score_candidate

router = APIRouter()

SOURCE = "openlibrary"


def _key(work_key: str) -> SourceKey:
    return SourceKey(source=SOURCE, key=work_key)


# --------------------------------------------------------------------------- models


class ResolveRequest(BlockingQuery):
    """A `BlockingQuery` plus how many candidates to return and two
    diff-only fields.

    `limit` (ruling R75) truncates only the RETURNED candidate list, after
    scoring and `decide` have already run over every candidate blocking
    produced -- the decision is independent of it.

    `description` and `subjects` (R90) feed `build_diff` only: they are
    what WE hold, compared against each candidate's record, and never reach
    the matcher -- `NOT_FOR_THE_MATCHER` strips them (with `limit`) before
    the `BlockingQuery` is built, so blocking and scoring see exactly the
    contract `BlockingQuery` declares.

    R88: `extra="forbid"` -- `{"author": ..., "isbn": ...}` is a 422 naming
    the unknown fields, never a 200 that silently discarded the identifier.
    `BlockingQuery` itself is untouched (it is the matcher's contract).
    """

    model_config = ConfigDict(extra="forbid")

    limit: int = Field(10, ge=1, le=50)
    description: str | None = None
    subjects: list[str] = Field(default_factory=list)


# The `ResolveRequest` fields that are NOT part of `BlockingQuery`. Every
# field on `ResolveRequest` is either a `BlockingQuery` field or listed here;
# `test_api_resolve.py` pins that invariant so a new request field cannot
# be quietly dropped on the way to the matcher.
NOT_FOR_THE_MATCHER = frozenset({"limit", "description", "subjects"})


class ResolveDecision(BaseModel):
    """The matcher's verdict on this query, built from `decide.Decision`.

    This is the ONLY authoritative verdict in the response. A bare
    `work_key` never appears here or anywhere else in this module's
    responses -- see `ResolveCandidate.verdict` for how a non-chosen
    candidate's own `verdict` is derived instead (ruling R73/R74).
    """

    verdict: Literal["accept", "abstain", "reject"]
    key: SourceKey | None = None
    score: float | None = None
    margin: float | None = None
    reason: str


class ResolveCandidate(BaseModel):
    """One scored candidate.

    `ResolveResponse.decision` is the only authoritative verdict in this
    response. This candidate's `verdict` equals `decision.verdict` exactly
    when this is the candidate `decide()` chose (`key == decision.key`);
    every other candidate's `verdict` is a threshold-only readout --
    `"reject"` when its score is below `weights.reject_threshold`, else
    `"abstain"` -- so a non-top candidate is never `"accept"` (ruling R73).

    `margin` is this candidate's score minus the NEXT-ranked candidate's
    score, computed over the full ranking before `limit` truncates what is
    returned. A candidate with no next-ranked candidate to compare against
    -- including the top candidate when it is the only one -- has its own
    score as its margin: the same convention `decide()` uses for an absent
    runner-up (`runner_up = 0.0`). That convention is what makes
    `candidates[0].margin == decision.margin` hold whenever the top
    candidate is present in the response (ruling R85).

    `record` (R90) is this candidate's full `WorkRecord` -- exactly what
    `GET /works/{key}` would return, from the one `fetch_works` call
    `resolve()` already makes for the diff -- so a caller that accepts a
    candidate can fill title, description, year evidence and authors from
    it with no follow-up request. None only if that fetch missed (a
    candidate key with no `works` row), in which case `diff` is `[]` too.
    """

    key: SourceKey
    score: float
    rules: list[str]
    margin: float
    verdict: Literal["accept", "abstain", "reject"]
    evidence: dict[str, dict]
    conflicts: list[str]
    diff: list[DiffEntry]
    record: WorkRecord | None = None


class ResolveResponse(BaseModel):
    decision: ResolveDecision
    guards_tripped: list[str]
    volume_guards_tripped: list[str]
    candidates: list[ResolveCandidate]


# ----------------------------------------------------------------------------- diff


def _text_diff_kind(ours: str | None, theirs: str | None) -> DiffKind:
    """Ruling R86: compare two text fields by FINGERPRINT
    (`common.normalize.fingerprint`), not raw string equality, so
    "The great Gatsby" vs "The Great Gatsby" reads as `agreement` rather
    than a `conflict` a human has to clear. Falls through to `classify_diff`
    on the RAW values whenever either side has no usable fingerprint, so
    "both empty" is still `absent` and "one empty" is still `fill`."""
    ours_fp = fingerprint(ours)
    theirs_fp = fingerprint(theirs)
    if ours_fp and theirs_fp and ours_fp == theirs_fp:
        return "agreement"
    return classify_diff(ours, theirs)


def _list_diff_kind(ours: list[str], theirs: list[str], fp: Callable[[str], str]) -> DiffKind:
    """Ruling R86: the list counterpart of `_text_diff_kind` -- fingerprint
    every element (`fp`) before handing the two lists to `classify_diff`, so
    its set/enrichment logic runs on normalized names, not raw ones.

    R89: an element whose fingerprint is empty falls back to its RAW value
    (`fp(v) or v`), mirroring `_text_diff_kind`'s guard. `fingerprint`
    strips non-Latin scripts to "", so without this `["村上春樹"]` vs
    `["夏目漱石"]` compared as `[""] == [""]` and read as `agreement`."""
    return classify_diff([fp(v) or v for v in ours], [fp(v) or v for v in theirs])


def build_diff(request: ResolveRequest, record: WorkRecord) -> list[DiffEntry]:
    """The work-level diff between the query and one candidate's retrieval record.

    Covers exactly SIX fields, the ones both sides carry at the WORK level,
    in this order: `title`, `subtitle`, `description`, `first_published_year`
    (ours is `request.year`; theirs is what OL DECLARES --
    `record.year_evidence.declared_year` -- never the surrounding
    edition-year evidence collapsed into a single number), `authors`
    (primary names only, both sides), and `subjects` (ours is
    `request.subjects`, so a request carrying none sees a `fill` whenever
    OL has subjects at all, and one carrying some sees agreement/
    enrichment/conflict like any other list).

    Ruling R86: `title`/`subtitle`/`description` are compared by
    fingerprint (`_text_diff_kind`) and `authors`/`subjects` element-wise
    by fingerprint (`_list_diff_kind`, `name_fingerprint` for authors and
    `fingerprint` for subjects) -- a case/punctuation-only difference (or "F. Scott
    Fitzgerald" vs "F. Scott FITZGERALD") reads as `agreement`, which is
    what makes a 126k-row pass tractable rather than 126k manual reviews.
    Every `DiffEntry.ours`/`.theirs` below still carries the RAW value --
    fingerprints are compared, never displayed. `first_published_year` is
    numeric and unaffected: it still goes straight to `classify_diff`.

    Edition-level fields -- isbn13, languages, page_count, publisher, series
    -- are deliberately NOT diffed here: a work has many editions and no
    single "theirs" to compare against. See `GET /works/{key}/editions` for
    those.
    """
    theirs_year = record.year_evidence.declared_year if record.year_evidence else None
    theirs_authors = [author.name for author in record.authors]
    return [
        DiffEntry(
            field="title",
            ours=request.title,
            theirs=record.title,
            kind=_text_diff_kind(request.title, record.title),
        ),
        DiffEntry(
            field="subtitle",
            ours=request.subtitle,
            theirs=record.subtitle,
            kind=_text_diff_kind(request.subtitle, record.subtitle),
        ),
        DiffEntry(
            field="description",
            ours=request.description,
            theirs=record.description,
            kind=_text_diff_kind(request.description, record.description),
        ),
        DiffEntry(
            field="first_published_year",
            ours=request.year,
            theirs=theirs_year,
            kind=classify_diff(request.year, theirs_year),
        ),
        DiffEntry(
            field="authors",
            ours=request.author_names,
            theirs=theirs_authors,
            kind=_list_diff_kind(request.author_names, theirs_authors, name_fingerprint),
        ),
        DiffEntry(
            field="subjects",
            ours=request.subjects,
            theirs=record.subjects,
            kind=_list_diff_kind(request.subjects, record.subjects, fingerprint),
        ),
    ]


# ------------------------------------------------------------------------- pipeline


def _candidate_verdict(
    scored: ScoredCandidate, decision: Decision, weights: Weights
) -> Literal["accept", "abstain", "reject"]:
    """Ruling R73: `decision`'s own candidate carries `decision.verdict`;
    every other candidate is a threshold-only reject/abstain readout, never
    an accept."""
    if decision.work_key is not None and scored.work_key == decision.work_key:
        return decision.verdict
    return "reject" if scored.score < weights.reject_threshold else "abstain"


def resolve(
    cur: duckdb.DuckDBPyConnection, state: ArtifactState, request: ResolveRequest
) -> ResolveResponse:
    """The per-request resolution pipeline, testable without HTTP.

    Mirrors `eval.harness.prepare`/`evaluate` exactly: `generate_candidates`
    -> `identifier_hits` -> `load_work_views` over the candidate keys ->
    `score_candidate` for every key that has a view (a candidate blocking
    found but that has no view -- a stale key absent from `works` -- is
    skipped, same as the harness) -> `rank` -> `decide`, with
    `volume_guards_tripped` passed through from the SAME `BlockingResult`.
    """
    paths = state.paths
    weights = state.weights

    query = BlockingQuery.model_validate(request.model_dump(exclude=NOT_FOR_THE_MATCHER))
    blocking = generate_candidates(cur, paths, query)
    identifier_hits = blocking.identifier_hits
    views = load_work_views(cur, paths, list(blocking.candidates))

    scored = [
        score_candidate(query, views[key], rules, weights, identifier_hits=identifier_hits)
        for key, rules in blocking.candidates.items()
        if key in views
    ]
    ranked = rank(scored)
    decision = decide(scored, weights, volume_guards_tripped=blocking.volume_guards_tripped)

    # Per-candidate margin to the next-ranked candidate, computed over the
    # FULL ranking before `limit` truncates the returned list: a candidate's
    # margin is a fact about the field it was found in, not an artifact of
    # how many results the caller asked to see. A candidate with no
    # next-ranked candidate -- the last in the ranking, including a lone
    # candidate -- has its OWN score as its margin: the same "absent
    # runner-up counts as 0.0" convention `decide()` uses for
    # `decision.margin` (ruling R85), which is exactly what keeps
    # `candidates[0].margin == decision.margin`.
    margins = [
        ranked[i].score - (ranked[i + 1].score if i + 1 < len(ranked) else 0.0)
        for i in range(len(ranked))
    ]

    truncated = ranked[: request.limit]
    truncated_margins = margins[: request.limit]

    # R72: exactly one fetch_works call, over the RETURNED keys only. R90:
    # the same record rides on the candidate, so the caller never needs a
    # follow-up GET /works/{key}.
    records = fetch_works(cur, paths, [candidate.work_key for candidate in truncated])

    candidates = []
    for scored_candidate, margin in zip(truncated, truncated_margins, strict=True):
        record = records.get(scored_candidate.work_key)
        candidates.append(
            ResolveCandidate(
                key=_key(scored_candidate.work_key),
                score=scored_candidate.score,
                rules=scored_candidate.rules,
                margin=margin,
                verdict=_candidate_verdict(scored_candidate, decision, weights),
                evidence=scored_candidate.evidence,
                conflicts=scored_candidate.conflicts,
                diff=build_diff(request, record) if record is not None else [],
                record=record,
            )
        )

    return ResolveResponse(
        decision=ResolveDecision(
            verdict=decision.verdict,
            key=_key(decision.work_key) if decision.work_key is not None else None,
            score=decision.score,
            margin=decision.margin,
            reason=decision.reason,
        ),
        guards_tripped=blocking.guards_tripped,
        volume_guards_tripped=blocking.volume_guards_tripped,
        candidates=candidates,
    )


# ----------------------------------------------------------------------------- route


@router.post("/resolve", response_model=Envelope[ResolveResponse])
def post_resolve(request: ResolveRequest, state: ArtifactState = Depends(get_state)):
    """Sync on purpose: DuckDB blocks, and FastAPI runs a sync `def` route in
    its threadpool."""
    with cursor(state) as cur:
        response = resolve(cur, state, request)
    return Envelope(source_version=state.source_version, data=response)
