"""POST /resolve: candidates, evidence and a diff -- never a single answer.

The resolution half of the service. This is the harness's own per-case loop
(`eval.harness.prepare` + `evaluate`, read there first) run once per request,
on the request's own cursor: `generate_candidates` -> `identifier_hits` ->
`load_work_views` -> `score_candidate` for every key that has a view ->
`build_clusters` -> `rank` -> `decide(..., volume_guards_tripped=..., clusters=...)`.
The matcher's scratch tables are TEMP and cursor-local (R82), so concurrent requests never collide.

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
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, ConfigDict, Field

from common.normalize import fingerprint, name_fingerprint
from common.schemas import DiffEntry, DiffKind, Envelope, SourceKey, classify_diff
from openlibrary.api.deps import ArtifactState, cursor, get_state
from openlibrary.api.limits import Busy, Deadline
from openlibrary.api.retrieval import WorkRecord, fetch_redirect_sources, fetch_works
from openlibrary.matcher.blocking import BlockingQuery, generate_candidates
from openlibrary.matcher.cluster import build_clusters, cluster_inputs
from openlibrary.matcher.decide import Decision, decide, margins, rank
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

    `duplicates` lists the other members of the winning duplicate cluster
    (empty when the winner is in none). `score` is the cluster's best score,
    which can exceed `candidates[0].score` when the representative is not
    the top scorer.

    `duplicate_redirect_sources` lists every old key that redirects to any
    of `duplicates`, sorted. A caller asking "do we already hold this book?"
    checks `key`, its candidate's `redirect_sources`, `duplicates` and these.
    It rides on the decision because a duplicate can sit past `limit`, where
    no returned candidate carries its keys.
    """

    verdict: Literal["accept", "abstain", "reject"]
    key: SourceKey | None = None
    score: float | None = None
    margin: float | None = None
    reason: str
    duplicates: list[SourceKey] = Field(default_factory=list)
    duplicate_redirect_sources: list[SourceKey] = Field(default_factory=list)


class ResolveCandidate(BaseModel):
    """One scored candidate.

    `ResolveResponse.decision` is the only authoritative verdict in this
    response. This candidate's `verdict` equals `decision.verdict` exactly
    when this is the candidate `decide()` chose (`key == decision.key`);
    every other candidate's `verdict` is a threshold-only readout --
    `"reject"` when its score is below `weights.reject_threshold`, else
    `"abstain"` -- so a non-top candidate is never `"accept"` (ruling R73).

    Candidates come in `decide.rank()` order: identity-bearing candidates
    (a title or identifier signal) first, then by duplicate-group best
    score with each group kept together, representative first, then score,
    then work_key.

    `margin` is this candidate's duplicate-group best score minus the best
    identity-bearing candidate ranked below it outside its group, computed over the full ranking
    before `limit` truncates what is returned. With no such candidate -- including
    the top candidate when it is the only one -- it is the candidate's own
    score: the same convention `decide()` uses for an absent runner-up.
    That convention is what makes
    `candidates[0].margin == decision.margin` hold whenever the top
    candidate is present in the response (ruling R85).

    `record` (R90) is this candidate's full `WorkRecord` -- exactly what
    `GET /works/{key}` would return, from the one `fetch_works` call
    `resolve()` already makes for the diff -- so a caller that accepts a
    candidate can fill title, description, year evidence and authors from
    it with no follow-up request. None only if that fetch missed (a
    candidate key with no `works` row), in which case `diff` is `[]` too.

    `redirect_sources` lists every old key that redirects to this work,
    sorted, so a caller can find a record it stored under a stale key.
    `record.redirected_from` cannot do that job: it names only the key that
    was requested, and a candidate's key is always the terminal one.
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
    redirect_sources: list[SourceKey] = Field(default_factory=list)


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
    skipped, same as the harness) -> `build_clusters` -> `rank(scored, clusters)`
    -> `decide(..., clusters=clusters)` -> `margins(ranked, clusters)`, with
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
    clusters = build_clusters(
        scored,
        {key: cluster_inputs(views[key]) for key in blocking.candidates if key in views},
        weights,
    )
    ranked = rank(scored, clusters)
    decision = decide(
        scored, weights, volume_guards_tripped=blocking.volume_guards_tripped, clusters=clusters
    )

    # Per-candidate margin, computed over the FULL ranking before `limit`
    # truncates the returned list: a candidate's margin is a fact about the
    # field it was found in. It is the candidate's duplicate-group best score minus the best
    # identity-bearing candidate ranked below it outside its duplicate group
    # (0.0 if none), the same cluster-aware `margins()` that `decide()` uses
    # (ruling R85), which keeps `candidates[0].margin == decision.margin`.
    candidate_margins = margins(ranked, clusters)

    truncated = ranked[: request.limit]
    truncated_margins = candidate_margins[: request.limit]

    # R72: exactly one fetch_works call, over the RETURNED keys only. R90:
    # the same record rides on the candidate, so the caller never needs a
    # follow-up GET /works/{key}.
    records = fetch_works(cur, paths, [candidate.work_key for candidate in truncated])
    # One reverse-redirect query covers the returned candidates and every
    # duplicate, returned or not.
    redirect_sources = fetch_redirect_sources(
        cur, paths, [candidate.work_key for candidate in truncated] + list(decision.duplicates)
    )

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
                redirect_sources=[_key(k) for k in redirect_sources[scored_candidate.work_key]],
            )
        )

    return ResolveResponse(
        decision=ResolveDecision(
            verdict=decision.verdict,
            key=_key(decision.work_key) if decision.work_key is not None else None,
            score=decision.score,
            margin=decision.margin,
            reason=decision.reason,
            duplicates=[_key(k) for k in decision.duplicates],
            duplicate_redirect_sources=[
                _key(k)
                for k in sorted({s for d in decision.duplicates for s in redirect_sources[d]})
            ],
        ),
        guards_tripped=blocking.guards_tripped,
        volume_guards_tripped=blocking.volume_guards_tripped,
        candidates=candidates,
    )


# ----------------------------------------------------------------------------- route


# How long a caller turned away as busy should wait before asking again.
# Short, because callers poll rather than queue (a busy answer costs a few
# milliseconds): a long wait would leave the slot idle after it frees up.
# The Rails client (Books::OpenLibrary::BaseClient#busy?) recognizes busy by
# the detail's "busy:" prefix, which `limits.Busy` supplies.
BUSY_RETRY_AFTER_S = 2


@router.post("/resolve", response_model=Envelope[ResolveResponse])
def post_resolve(request: ResolveRequest, state: ArtifactState = Depends(get_state)):
    """Sync on purpose: DuckDB blocks, and FastAPI runs a sync `def` route in
    its threadpool.

    At most `state.resolve_slots.limit` run at once; the next is a 503 at
    once, never a queue. One still running at `state.resolve_deadline_s` is
    interrupted and answered 504 (`openlibrary.api.limits`)."""
    try:
        with (
            state.resolve_slots.hold(),
            cursor(state) as cur,
            Deadline(cur, state.resolve_deadline_s) as deadline,
        ):
            try:
                response = resolve(cur, state, request)
            except duckdb.InterruptException:
                if not deadline.expired:
                    raise
                raise HTTPException(
                    status_code=504,
                    detail=f"deadline: resolve stopped after {state.resolve_deadline_s:g} s",
                ) from None
    except Busy as exc:
        raise HTTPException(
            status_code=503, detail=str(exc), headers={"Retry-After": str(BUSY_RETRY_AFTER_S)}
        ) from None
    return Envelope(source_version=state.source_version, data=response)
