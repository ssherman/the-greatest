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
`build_diff`.
"""

from __future__ import annotations

from typing import Literal

import duckdb
from fastapi import APIRouter, Depends
from pydantic import BaseModel, Field

from common.schemas import DiffEntry, Envelope, SourceKey, classify_diff
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
    """A `BlockingQuery` plus how many candidates to return.

    `limit` (ruling R75) truncates only the RETURNED candidate list, after
    scoring and `decide` have already run over every candidate blocking
    produced -- the decision is independent of it.
    """

    limit: int = Field(10, ge=1, le=50)


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
    """

    key: SourceKey
    score: float
    rules: list[str]
    margin: float
    verdict: Literal["accept", "abstain", "reject"]
    evidence: dict[str, dict]
    conflicts: list[str]
    diff: list[DiffEntry]


class ResolveResponse(BaseModel):
    decision: ResolveDecision
    guards_tripped: list[str]
    volume_guards_tripped: list[str]
    candidates: list[ResolveCandidate]


# ----------------------------------------------------------------------------- diff


def build_diff(request: ResolveRequest, record: WorkRecord) -> list[DiffEntry]:
    """The work-level diff between the query and one candidate's retrieval record.

    Covers exactly the fields both sides carry at the WORK level: `title`,
    `subtitle`, `first_published_year` (ours is `request.year`; theirs is
    what OL DECLARES -- `record.year_evidence.declared_year` -- never the
    surrounding edition-year evidence collapsed into a single number),
    `authors` (primary names only, both sides), and `subjects` (the request
    never carries any, so `ours=[]` here and this is a `fill` whenever OL
    has subjects at all). Each entry's `kind` comes from
    `common.schemas.classify_diff`.

    Edition-level fields -- isbn13, languages, page_count, publisher, series
    -- are deliberately NOT diffed here: a work has many editions and no
    single "theirs" to compare against. See `GET /works/{key}/editions` for
    those.
    """
    theirs_year = record.year_evidence.declared_year if record.year_evidence else None
    theirs_authors = [author.name for author in record.authors]
    fields: list[tuple[str, object, object]] = [
        ("title", request.title, record.title),
        ("subtitle", request.subtitle, record.subtitle),
        ("first_published_year", request.year, theirs_year),
        ("authors", request.author_names, theirs_authors),
        ("subjects", [], record.subjects),
    ]
    return [
        DiffEntry(field=name, ours=ours, theirs=theirs, kind=classify_diff(ours, theirs))
        for name, ours, theirs in fields
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

    query = BlockingQuery.model_validate(request.model_dump(exclude={"limit"}))
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
    # how many results the caller asked to see (0.0 for the last).
    margins = [
        ranked[i].score - (ranked[i + 1].score if i + 1 < len(ranked) else 0.0)
        for i in range(len(ranked))
    ]

    truncated = ranked[: request.limit]
    truncated_margins = margins[: request.limit]

    # R72: exactly one fetch_works call, over the RETURNED keys only.
    records = fetch_works(cur, paths, [candidate.work_key for candidate in truncated])

    candidates = [
        ResolveCandidate(
            key=_key(scored_candidate.work_key),
            score=scored_candidate.score,
            rules=scored_candidate.rules,
            margin=margin,
            verdict=_candidate_verdict(scored_candidate, decision, weights),
            evidence=scored_candidate.evidence,
            conflicts=scored_candidate.conflicts,
            diff=build_diff(request, record)
            if (record := records.get(scored_candidate.work_key)) is not None
            else [],
        )
        for scored_candidate, margin in zip(truncated, truncated_margins, strict=True)
    ]

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
