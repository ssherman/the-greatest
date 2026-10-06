"""POST /resolve: candidates, evidence and diffs -- never a single answer.

Every discovery query below carries an ORDER BY and a predicate that pins the
shape the test needs (ruling R43/R69) -- a flaky discovery query cost this
project a day. `a_resolvable_title` uses `length(title_fp) >= 4 AND
title_fp_freq = 1` (ruling R69): a unique, fingerprintable title, so blocking
rule 4 finds it and the case is not accidentally degenerate
(`common.normalize.MIN_BLOCKING_FP_LENGTH` is 4).
"""

from __future__ import annotations

import duckdb
import pytest
from fastapi.testclient import TestClient

from openlibrary.api.deps import Settings, open_artifact
from openlibrary.api.main import create_app
from openlibrary.matcher.scorer import ScoredCandidate, has_identity_evidence


@pytest.fixture(scope="module")
def client(fixture_artifact):
    state = open_artifact(
        Settings(data_root=fixture_artifact.root, data_version=fixture_artifact.dump_date)
    )
    with TestClient(create_app(state)) as test_client:
        yield test_client


def _con():
    return duckdb.connect()


@pytest.fixture(scope="module")
def a_resolvable_title(fixture_artifact) -> str:
    """A unique, fingerprintable title (ruling R69's discovery query)."""
    con = _con()
    row = con.execute(
        f"""
        SELECT title FROM '{fixture_artifact.table("works")}'
        WHERE length(title_fp) >= 4 AND title_fp_freq = 1
        ORDER BY work_key LIMIT 1
        """
    ).fetchone()
    con.close()
    assert row is not None, "fixture corpus lost its unique, fingerprintable title"
    return row[0]


@pytest.fixture(scope="module")
def a_title_and_year_that_agree(fixture_artifact) -> tuple[str, int]:
    """A unique, fingerprintable title (ruling R69's shape predicate) whose
    work has a declared year -- so `candidates[0]` is provably the work
    whose `declared_year` this fixture just read, not merely A work that
    happens to have one."""
    con = _con()
    row = con.execute(
        f"""
        SELECT w.title, d.declared_year FROM '{fixture_artifact.table("works")}' w
        JOIN '{fixture_artifact.table("work_details")}' d USING (work_key)
        WHERE length(w.title_fp) >= 4 AND w.title_fp_freq = 1 AND d.declared_year IS NOT NULL
        ORDER BY w.work_key LIMIT 1
        """
    ).fetchone()
    con.close()
    if row is None:
        pytest.skip("fixture corpus has no uniquely-titled work with a declared year")
    return row[0], row[1]


@pytest.fixture(scope="module")
def a_title_with_multiple_candidates(fixture_artifact) -> str:
    """A title whose title_fp is shared by >=2 works (ruling R69's discovery
    query) -- needed so the R73 "no non-chosen candidate is accept" test is
    not vacuous against a single-candidate resolve (Important 2)."""
    con = _con()
    row = con.execute(
        f"""
        SELECT title FROM '{fixture_artifact.table("works")}'
        WHERE title_fp <> '' AND title_fp_freq >= 2
        ORDER BY work_key LIMIT 1
        """
    ).fetchone()
    con.close()
    assert row is not None, "fixture corpus lost its multi-candidate title"
    return row[0]


@pytest.fixture(scope="module")
def weights():
    """The real, currently calibrated thresholds -- `state.weights` is
    exactly `load_weights()` (see `deps.open_artifact`), so this is the same
    object the running service scores against. Tests derive expectations
    from this, never from a literal threshold number."""
    from openlibrary.matcher.scorer import load_weights

    return load_weights()


def test_resolve_always_returns_a_list_of_candidates(client, a_resolvable_title):
    data = client.post("/resolve", json={"title": a_resolvable_title}).json()["data"]
    # No resolve returns a single answer: a guess must never be mistakable for a fact.
    assert isinstance(data["candidates"], list)


def test_a_query_that_matches_nothing_returns_an_empty_list_and_a_reject(client):
    # "Zzzq Nothing Whatsoever Matches This String" risks a fuzzy blocking
    # rule 6 (character-set Jaccard, TRIGRAM_MIN_SIMILARITY = 0.55) hit
    # against the real corpus (resolution 5's replacement title); a title
    # built from only two letters has a character set small enough that no
    # real title's fingerprint can reach that threshold against it.
    data = client.post("/resolve", json={"title": "Qqqq Zzzz Qzqz"}).json()["data"]
    assert data["candidates"] == []
    assert data["decision"]["verdict"] == "reject"


def test_every_candidate_carries_its_key_score_rules_margin_verdict_evidence_and_diff(
    client, a_resolvable_title
):
    candidates = client.post("/resolve", json={"title": a_resolvable_title}).json()["data"][
        "candidates"
    ]
    assert candidates
    first = candidates[0]
    for field in ("key", "score", "rules", "margin", "verdict", "evidence", "diff", "conflicts"):
        assert field in first
    assert first["key"]["source"] == "openlibrary"


def test_candidates_are_ordered_as_decide_rank_orders_them(client, a_resolvable_title):
    """Identity-bearing candidates first, then score descending, then work_key."""
    candidates = client.post("/resolve", json={"title": a_resolvable_title}).json()["data"][
        "candidates"
    ]

    def has_identity(c):
        return has_identity_evidence(
            ScoredCandidate(
                work_key=c["key"]["key"],
                score=c["score"],
                rules=c["rules"],
                evidence=c["evidence"],
                conflicts=c["conflicts"],
            )
        )

    order = [(not has_identity(c), -c["score"], c["key"]["key"]) for c in candidates]
    assert order == sorted(order)


def test_top_candidate_margin_matches_the_decision_margin(client, a_resolvable_title):
    """Ruling R85: `candidates[0].margin` uses the same "absent runner-up
    counts as 0.0" convention `decide()` uses for `decision.margin`, so the
    two must agree whenever the top candidate is returned. `a_resolvable_title`
    (title_fp_freq == 1) is also the single-candidate case: with no
    runner-up at all, the top (and only) candidate's margin equals its own
    score."""
    data = client.post("/resolve", json={"title": a_resolvable_title}).json()["data"]
    candidates = data["candidates"]
    assert candidates
    assert candidates[0]["margin"] == data["decision"]["margin"]
    assert len(candidates) == 1, "fixture corpus gained a second candidate for this title"
    assert candidates[0]["margin"] == candidates[0]["score"]


def test_guards_that_tripped_are_reported_rather_than_hidden(client):
    data = client.post("/resolve", json={"title": "!!!"}).json()["data"]
    # A visible gap beats a query that never returns.
    assert "title_fp" in data["guards_tripped"]


def test_an_empty_local_field_shows_up_as_a_fill(client, a_title_and_year_that_agree):
    title, _year = a_title_and_year_that_agree
    # We send no year at all, so their year is a FILL -- safe to apply in bulk.
    candidates = client.post("/resolve", json={"title": title}).json()["data"]["candidates"]
    diffs = {d["field"]: d["kind"] for d in candidates[0]["diff"]}
    assert diffs.get("first_published_year") in ("fill", "agreement")


def test_a_disagreeing_local_field_shows_up_as_a_conflict(client, a_title_and_year_that_agree):
    title, year = a_title_and_year_that_agree
    candidates = client.post("/resolve", json={"title": title, "year": year + 40}).json()["data"][
        "candidates"
    ]
    diffs = {d["field"]: d["kind"] for d in candidates[0]["diff"]}
    assert diffs.get("first_published_year") == "conflict"


def _work_record(**overrides):
    from common.schemas import SourceKey
    from openlibrary.api.retrieval import WorkRecord

    defaults = {"key": SourceKey(source="openlibrary", key="OL1W"), "title": "The Great Gatsby"}
    defaults.update(overrides)
    return WorkRecord(**defaults)


def test_a_title_differing_only_in_case_and_punctuation_is_an_agreement():
    """Ruling R86: `build_diff` compares `title` by fingerprint, so noise a
    human would never call a real disagreement doesn't read as `conflict`.
    Exercised directly against `build_diff` (no HTTP/blocking involved) so
    the two raw strings under comparison are exact and don't depend on
    which fixture-corpus title happens to be discoverable."""
    from openlibrary.api.resolve import ResolveRequest, build_diff

    request = ResolveRequest(title="the great gatsby!!!")
    record = _work_record(title="The Great Gatsby")
    diffs = {d.field: d for d in build_diff(request, record)}
    assert diffs["title"].kind == "agreement"
    # ours/theirs still carry the RAW values, never the fingerprint.
    assert diffs["title"].ours == "the great gatsby!!!"
    assert diffs["title"].theirs == "The Great Gatsby"


def test_authors_differing_only_in_case_is_an_agreement():
    """Ruling R86: `authors` is compared element-wise by `name_fingerprint`."""
    from common.schemas import SourceKey
    from openlibrary.api.resolve import ResolveRequest, build_diff
    from openlibrary.api.retrieval import AuthorRef

    request = ResolveRequest(title="anything", author_names=["F. Scott FITZGERALD"])
    record = _work_record(
        authors=[
            AuthorRef(key=SourceKey(source="openlibrary", key="OL1A"), name="F. Scott Fitzgerald")
        ]
    )
    diffs = {d.field: d for d in build_diff(request, record)}
    assert diffs["authors"].kind == "agreement"
    assert diffs["authors"].ours == ["F. Scott FITZGERALD"]
    assert diffs["authors"].theirs == ["F. Scott Fitzgerald"]


def test_a_genuinely_different_title_is_still_a_conflict():
    """Ruling R86: fingerprinting must not paper over an actual mismatch."""
    from openlibrary.api.resolve import ResolveRequest, build_diff

    request = ResolveRequest(title="The Great Gatsby")
    record = _work_record(title="Moby-Dick")
    diffs = {d.field: d for d in build_diff(request, record)}
    assert diffs["title"].kind == "conflict"


def test_the_decision_is_separate_from_the_candidates(client, a_resolvable_title):
    data = client.post("/resolve", json={"title": a_resolvable_title}).json()["data"]
    assert data["decision"]["verdict"] in ("accept", "abstain", "reject")
    assert "reason" in data["decision"]


def test_resolve_never_writes_anything(client, fixture_artifact):
    before = {
        name: fixture_artifact.table(name).stat().st_mtime for name in ("works", "identifiers")
    }
    client.post("/resolve", json={"title": "anything at all"})
    after = {
        name: fixture_artifact.table(name).stat().st_mtime for name in ("works", "identifiers")
    }
    assert before == after


def test_a_non_marc_language_is_rejected_with_422(client):
    assert client.post("/resolve", json={"title": "Anything", "language": "en"}).status_code == 422
    assert client.post("/resolve", json={"title": "Anything", "language": "eng"}).status_code == 200


def test_limit_truncates_the_candidate_list_but_not_the_decision(client, fixture_artifact):
    con = _con()
    row = con.execute(
        f"""
        SELECT title FROM '{fixture_artifact.table("works")}'
        WHERE title_fp <> '' AND title_fp_freq >= 2
        ORDER BY work_key LIMIT 1
        """
    ).fetchone()
    con.close()
    if row is not None:
        (title,) = row
    else:
        con = _con()
        (title,) = con.execute(
            f"""
            SELECT title FROM '{fixture_artifact.table("works")}'
            WHERE length(title_fp) >= 4 AND title_fp_freq = 1
            ORDER BY work_key LIMIT 1
            """
        ).fetchone()
        con.close()

    full = client.post("/resolve", json={"title": title, "limit": 50}).json()["data"]
    limited = client.post("/resolve", json={"title": title, "limit": 1}).json()["data"]

    assert len(limited["candidates"]) <= 1
    assert len(limited["candidates"]) <= len(full["candidates"])
    assert limited["decision"] == full["decision"]
    if row is not None:
        assert len(full["candidates"]) >= 2


def test_candidate_verdict_is_threshold_only_for_every_non_chosen_candidate(weights):
    """Important 2 (unit level): `_candidate_verdict` directly, with
    constructed inputs, so the "non-chosen carries a threshold readout, not
    `decision.verdict`" rule is exercised even when the corpus offers only
    one candidate for every discoverable title. `above_reject` is the case
    that would be WRONG if the code copied `decision.verdict` onto every
    high-scoring candidate instead of only the chosen one: it scores well
    above `reject_threshold` while `decision.verdict` is "accept", and must
    still read "abstain", never "accept" (ruling R73)."""
    from openlibrary.api.resolve import _candidate_verdict
    from openlibrary.matcher.decide import Decision
    from openlibrary.matcher.scorer import ScoredCandidate

    decision = Decision(verdict="accept", work_key="OL1W", score=0.95, margin=0.3, reason="x")
    chosen = ScoredCandidate(work_key="OL1W", score=0.95)
    # Derived from weights.reject_threshold, never a literal: under the
    # currently calibrated weights.json (reject_threshold 0.4) these land on
    # 0.65 and 0.2, exactly the review's worked example.
    above_reject = ScoredCandidate(work_key="OL2W", score=weights.reject_threshold + 0.25)
    below_reject = ScoredCandidate(work_key="OL3W", score=max(weights.reject_threshold - 0.2, 0.0))

    verdicts = [
        _candidate_verdict(chosen, decision, weights),
        _candidate_verdict(above_reject, decision, weights),
        _candidate_verdict(below_reject, decision, weights),
    ]
    assert verdicts == ["accept", "abstain", "reject"]


def test_the_decided_candidate_carries_the_decision_verdict_and_no_other_accepts(
    client, a_title_with_multiple_candidates
):
    """Important 2 (end-to-end): a title with >=2 candidates, so this is not
    vacuous the way it was against a single-candidate resolve."""
    data = client.post(
        "/resolve", json={"title": a_title_with_multiple_candidates, "limit": 50}
    ).json()["data"]
    decision = data["decision"]
    assert len(data["candidates"]) >= 2, "expected >=2 candidates for this title"
    saw_decision_key = False
    other_verdicts = set()
    for candidate in data["candidates"]:
        if decision["key"] is not None and candidate["key"] == decision["key"]:
            assert candidate["verdict"] == decision["verdict"]
            saw_decision_key = True
        else:
            other_verdicts.add(candidate["verdict"])
    if decision["key"] is not None:
        assert saw_decision_key
    assert "accept" not in other_verdicts
    assert other_verdicts <= {"abstain", "reject"}


def test_every_key_is_namespaced_and_no_bare_work_key_leaks(client, a_resolvable_title):
    response = client.post("/resolve", json={"title": a_resolvable_title, "limit": 50})
    assert "work_key" not in response.text
    data = response.json()["data"]
    if data["decision"]["key"] is not None:
        assert data["decision"]["key"]["source"] == "openlibrary"
    for candidate in data["candidates"]:
        assert candidate["key"]["source"] == "openlibrary"


# -------------------------------------------------------------- request strictness (R88)


def test_a_resolve_request_with_unknown_fields_is_a_422_naming_them(client):
    """R88: `ResolveRequest` is `extra="forbid"`. The spec-shaped body below
    used to validate as `{"title": ...}` and return 200 with the ISBN
    silently discarded -- the caller believed its identifier had been used."""
    response = client.post(
        "/resolve",
        json={
            "title": "The Great Gatsby",
            "author": "F. Scott Fitzgerald",
            "isbn": "9780743273565",
        },
    )
    assert response.status_code == 422
    rejected = {
        loc for error in response.json()["detail"] for loc in error["loc"] if isinstance(loc, str)
    }
    assert {"author", "isbn"} <= rejected


# ------------------------------------------------------- fingerprint fallback (R89)


def test_two_names_that_fingerprint_to_nothing_are_a_conflict_not_an_agreement():
    """R89: `fingerprint` strips non-Latin scripts to "", so without a
    fallback two DIFFERENT Japanese names both mapped to "" and read as
    `agreement`. `_list_diff_kind` now compares `fp(v) or v`."""
    from common.normalize import name_fingerprint
    from openlibrary.api.resolve import _list_diff_kind

    assert name_fingerprint("村上春樹") == "" == name_fingerprint("夏目漱石")
    assert _list_diff_kind(["村上春樹"], ["夏目漱石"], name_fingerprint) == "conflict"


def test_the_same_unfingerprintable_name_on_both_sides_is_still_an_agreement():
    from common.normalize import name_fingerprint
    from openlibrary.api.resolve import _list_diff_kind

    assert _list_diff_kind(["村上春樹"], ["村上春樹"], name_fingerprint) == "agreement"


def test_unfingerprintable_authors_conflict_through_build_diff():
    from common.schemas import SourceKey
    from openlibrary.api.resolve import ResolveRequest, build_diff
    from openlibrary.api.retrieval import AuthorRef

    request = ResolveRequest(title="anything", author_names=["村上春樹"])
    record = _work_record(
        authors=[AuthorRef(key=SourceKey(source="openlibrary", key="OL1A"), name="夏目漱石")]
    )
    diffs = {d.field: d for d in build_diff(request, record)}
    assert diffs["authors"].kind == "conflict"


# ------------------------------------------------- a candidate carries its record (R90)


@pytest.fixture(scope="module")
def a_resolvable_title_with_year_evidence(fixture_artifact) -> tuple[str, str]:
    """(title, work_key) for a unique, fingerprintable title (ruling R69)
    whose work has a `year_evidence` row -- so `record.year_evidence` on the
    returned candidate is a real assertion, not a None that happens to be
    allowed."""
    con = _con()
    row = con.execute(
        f"""
        SELECT w.title, w.work_key FROM '{fixture_artifact.table("works")}' w
        JOIN '{fixture_artifact.table("year_evidence")}' y USING (work_key)
        WHERE length(w.title_fp) >= 4 AND w.title_fp_freq = 1
        ORDER BY w.work_key LIMIT 1
        """
    ).fetchone()
    con.close()
    assert row is not None, "fixture corpus lost its uniquely-titled work with year evidence"
    return row[0], row[1]


def test_every_candidate_carries_the_record_get_works_would_return(
    client, a_resolvable_title_with_year_evidence
):
    """R90: Rails fills title/first_published_year/description from an
    accepted candidate and needs `year_evidence` (declared_year exists for
    10.7% of works), so the candidate carries the WorkRecord `resolve()`
    already fetched -- no follow-up `GET /works/{key}` needed."""
    title, work_key = a_resolvable_title_with_year_evidence
    candidates = client.post("/resolve", json={"title": title}).json()["data"]["candidates"]
    assert candidates
    candidate = next(c for c in candidates if c["key"]["key"] == work_key)
    record = candidate["record"]
    assert record is not None
    assert record["key"] == candidate["key"]
    assert record["year_evidence"] is not None
    assert "declared_year" in record["year_evidence"]
    # Exactly what GET /works/{key} returns.
    assert record == client.get(f"/works/{work_key}").json()["data"]


def test_the_diff_covers_exactly_six_work_level_fields_in_order():
    from openlibrary.api.resolve import ResolveRequest, build_diff

    diffs = build_diff(ResolveRequest(title="anything"), _work_record())
    assert [d.field for d in diffs] == [
        "title",
        "subtitle",
        "description",
        "first_published_year",
        "authors",
        "subjects",
    ]


def test_a_description_matching_ols_by_fingerprint_is_an_agreement():
    from openlibrary.api.resolve import ResolveRequest, build_diff

    request = ResolveRequest(title="anything", description="A novel of the Jazz Age!")
    record = _work_record(description="A novel of the Jazz Age.")
    diffs = {d.field: d for d in build_diff(request, record)}
    assert diffs["description"].kind == "agreement"
    assert diffs["description"].ours == "A novel of the Jazz Age!"
    assert diffs["description"].theirs == "A novel of the Jazz Age."


def test_a_differing_description_is_a_conflict():
    from openlibrary.api.resolve import ResolveRequest, build_diff

    request = ResolveRequest(title="anything", description="A whaling voyage.")
    record = _work_record(description="A novel of the Jazz Age.")
    diffs = {d.field: d for d in build_diff(request, record)}
    assert diffs["description"].kind == "conflict"


def test_a_description_absent_locally_is_a_fill():
    from openlibrary.api.resolve import ResolveRequest, build_diff

    diffs = {
        d.field: d
        for d in build_diff(
            ResolveRequest(title="anything"), _work_record(description="A novel of the Jazz Age.")
        )
    }
    assert diffs["description"].kind == "fill"


def test_our_subjects_are_compared_against_theirs():
    """`subjects` is no longer a permanent fill: the request may carry ours."""
    from openlibrary.api.resolve import ResolveRequest, build_diff

    record = _work_record(subjects=["Fiction", "Jazz Age"])
    agree = build_diff(ResolveRequest(title="x", subjects=["fiction", "JAZZ AGE"]), record)
    enrich = build_diff(ResolveRequest(title="x", subjects=["Fiction"]), record)
    fill = build_diff(ResolveRequest(title="x"), record)
    kinds = {
        label: {d.field: d.kind for d in diffs}["subjects"]
        for label, diffs in (("agree", agree), ("enrich", enrich), ("fill", fill))
    }
    assert kinds == {"agree": "agreement", "enrich": "enrichment", "fill": "fill"}


def test_every_request_field_is_either_the_matchers_or_listed_as_not_for_it():
    """`description`/`subjects` are diff-only inputs and `BlockingQuery` (the
    matcher's contract, untouched) has no such fields. `BlockingQuery` runs
    under pydantic's default `extra="ignore"`, so a `ResolveRequest` field
    that is neither a `BlockingQuery` field nor in `NOT_FOR_THE_MATCHER`
    would be dropped SILENTLY on the way to blocking -- this pins the
    partition so that cannot happen to the next field someone adds."""
    from openlibrary.api.resolve import NOT_FOR_THE_MATCHER, ResolveRequest
    from openlibrary.matcher.blocking import BlockingQuery

    assert set(ResolveRequest.model_fields) - NOT_FOR_THE_MATCHER == set(BlockingQuery.model_fields)
    assert NOT_FOR_THE_MATCHER.isdisjoint(BlockingQuery.model_fields)


def test_a_request_carrying_description_and_subjects_resolves_end_to_end(client):
    """With `extra="forbid"` on (R88) this is only a 200 because the two
    fields are declared on `ResolveRequest` (R90) and stripped before the
    matcher sees them."""
    response = client.post(
        "/resolve",
        json={"title": "anything", "description": "words", "subjects": ["Fiction"]},
    )
    assert response.status_code == 200


def test_top_candidate_margin_matches_the_decision_margin_with_several_candidates(
    client, a_title_with_multiple_candidates
):
    data = client.post(
        "/resolve", json={"title": a_title_with_multiple_candidates, "limit": 50}
    ).json()["data"]
    candidates = data["candidates"]
    assert len(candidates) >= 2
    assert candidates[0]["margin"] == pytest.approx(data["decision"]["margin"])


def test_margins_ignore_a_titleless_candidate_that_outscores_the_titled_one(
    client, a_title_with_multiple_candidates, monkeypatch
):
    """rank() puts the titled candidate (0.885) above the title-less one (0.913);
    a margin taken against the NEXT-ranked candidate by score would go negative
    or disagree with the decision."""
    import openlibrary.api.resolve as resolve_module

    real = resolve_module.score_candidate
    calls = []

    def stubbed(*args, **kwargs):
        scored = real(*args, **kwargs)
        calls.append(scored.work_key)
        if len(calls) == 1:
            evidence = {"title_similarity": {"value": 0.9, "weight": 1.0, "contribution": 0.885}}
            return scored.model_copy(update={"score": 0.885, "evidence": evidence, "conflicts": []})
        evidence = {"author_overlap": {"value": 1.0, "weight": 1.0, "contribution": 0.913}}
        return scored.model_copy(update={"score": 0.913, "evidence": evidence, "conflicts": []})

    monkeypatch.setattr(resolve_module, "score_candidate", stubbed)
    data = client.post(
        "/resolve", json={"title": a_title_with_multiple_candidates, "limit": 50}
    ).json()["data"]
    candidates = data["candidates"]
    assert len(candidates) >= 2
    assert candidates[0]["key"]["key"] == calls[0]
    assert candidates[0]["margin"] == pytest.approx(data["decision"]["margin"])
    assert all(c["margin"] >= 0 for c in candidates)


def test_the_decision_carries_a_duplicates_list_of_keys(client, a_title_with_multiple_candidates):
    data = client.post("/resolve", json={"title": a_title_with_multiple_candidates}).json()["data"]
    duplicates = data["decision"]["duplicates"]
    assert isinstance(duplicates, list)
    assert all(set(d) == {"source", "key"} for d in duplicates)


def test_r85_holds_with_cluster_aware_margins_across_several_candidates(
    client, a_title_with_multiple_candidates
):
    data = client.post("/resolve", json={"title": a_title_with_multiple_candidates}).json()["data"]
    assert len(data["candidates"]) >= 2
    assert data["candidates"][0]["margin"] == pytest.approx(data["decision"]["margin"])


def test_resolve_hands_one_cluster_index_to_rank_decide_and_margins(
    client, a_title_with_multiple_candidates, monkeypatch
):
    import openlibrary.api.resolve as resolve_module

    seen = {}

    def spy(name, clusters_of):
        real = getattr(resolve_module, name)

        def wrapper(*args, **kwargs):
            seen[name] = clusters_of(args, kwargs)
            return real(*args, **kwargs)

        monkeypatch.setattr(resolve_module, name, wrapper)

    spy("rank", lambda a, k: a[1] if len(a) > 1 else k.get("clusters"))
    spy("margins", lambda a, k: a[1] if len(a) > 1 else k.get("clusters"))
    spy("decide", lambda a, k: k.get("clusters"))
    client.post("/resolve", json={"title": a_title_with_multiple_candidates})
    assert all(seen[name] is not None for name in ("rank", "decide", "margins"))
    assert seen["rank"] is seen["decide"] is seen["margins"]


def _force_one_cluster(monkeypatch, keys, edition_counts):
    """Make `keys` share a title and an author through the real clusterer, so
    they land in ONE cluster; every other work keeps its real inputs."""
    import openlibrary.api.resolve as resolve_module
    from openlibrary.matcher.cluster import ClusterInputs

    real = resolve_module.cluster_inputs

    def patched(view):
        if view.work_key not in keys:
            return real(view)
        return ClusterInputs(
            title_fp="onesharedtitleforthecluster",
            title_fp_noart="onesharedtitleforthecluster",
            title_raw="One Shared Title For The Cluster",
            author_fps=["onesharedauthor"],
            edition_count=edition_counts[view.work_key],
        )

    monkeypatch.setattr(resolve_module, "cluster_inputs", patched)


def _two_best_keys(client, title):
    candidates = client.post("/resolve", json={"title": title, "limit": 50}).json()["data"][
        "candidates"
    ]
    assert len(candidates) >= 2
    return candidates[0]["key"]["key"], candidates[1]["key"]["key"]


def test_a_cluster_whose_representative_is_the_lower_scorer_is_decided_as_one_candidate(
    client, a_title_with_multiple_candidates, monkeypatch
):
    top, other = _two_best_keys(client, a_title_with_multiple_candidates)
    _force_one_cluster(monkeypatch, {top, other}, {top: 1, other: 1000})
    data = client.post(
        "/resolve", json={"title": a_title_with_multiple_candidates, "limit": 50}
    ).json()["data"]
    decision, candidates = data["decision"], data["candidates"]
    assert decision["key"] == candidates[0]["key"] == {"source": "openlibrary", "key": other}
    assert decision["duplicates"] == [{"source": "openlibrary", "key": top}]
    assert candidates[0]["margin"] == pytest.approx(decision["margin"])
    assert candidates[0]["verdict"] == decision["verdict"]
    by_key = {c["key"]["key"]: c for c in candidates}
    assert by_key[top]["verdict"] in ("abstain", "reject")
    assert all(c["verdict"] in ("abstain", "reject") for c in candidates[1:])


def test_a_cluster_with_no_dominant_member_abstains_and_lists_the_other_member(
    client, a_title_with_multiple_candidates, monkeypatch
):
    top, other = _two_best_keys(client, a_title_with_multiple_candidates)
    _force_one_cluster(monkeypatch, {top, other}, {top: 5, other: 5})
    data = client.post(
        "/resolve", json={"title": a_title_with_multiple_candidates, "limit": 50}
    ).json()["data"]
    decision = data["decision"]
    assert decision["verdict"] == "abstain"
    assert decision["reason"].startswith("duplicate cluster with no dominant member")
    assert decision["duplicates"] == [{"source": "openlibrary", "key": other}]
    assert data["candidates"][0]["margin"] == pytest.approx(decision["margin"])


# ------------------------------------------------------------ redirect sources


def _redirect_sources(fixture_artifact, terminal: str) -> list[dict]:
    con = _con()
    rows = con.execute(
        f"""
        SELECT source_key FROM '{fixture_artifact.table("redirects")}'
        WHERE terminal_key = ? AND entity = 'work' AND NOT is_cycle AND NOT is_dangling
        ORDER BY source_key
        """,
        [terminal],
    ).fetchall()
    con.close()
    return [{"source": "openlibrary", "key": key} for (key,) in rows]


@pytest.fixture(scope="module")
def a_redirect_target_with_a_resolvable_title(fixture_artifact) -> tuple[str, str]:
    """A uniquely-titled work that at least one old key redirects to."""
    con = _con()
    row = con.execute(
        f"""
        SELECT w.title, w.work_key FROM '{fixture_artifact.table("works")}' w
        WHERE length(w.title_fp) >= 4 AND w.title_fp_freq = 1
          AND EXISTS (
            SELECT 1 FROM '{fixture_artifact.table("redirects")}' r
            WHERE r.terminal_key = w.work_key AND r.entity = 'work'
              AND NOT r.is_cycle AND NOT r.is_dangling
          )
        ORDER BY w.work_key LIMIT 1
        """
    ).fetchone()
    con.close()
    assert row is not None, "fixture corpus lost its uniquely-titled redirect target"
    return row


def test_every_candidate_lists_the_old_keys_that_redirect_to_it(
    client, fixture_artifact, a_redirect_target_with_a_resolvable_title
):
    """Rails finds a local book stored under a stale key through this list.
    `record.redirected_from` names only the REQUESTED key, so it is always
    empty here: /resolve candidates are terminal keys."""
    title, work_key = a_redirect_target_with_a_resolvable_title
    candidates = client.post("/resolve", json={"title": title}).json()["data"]["candidates"]
    candidate = next(c for c in candidates if c["key"]["key"] == work_key)
    expected = _redirect_sources(fixture_artifact, work_key)
    assert expected
    assert candidate["redirect_sources"] == expected
    for other in candidates:
        assert other["redirect_sources"] == _redirect_sources(fixture_artifact, other["key"]["key"])


def test_the_decision_lists_the_old_keys_of_every_duplicate(
    client, a_title_with_multiple_candidates, monkeypatch
):
    """A local book holding a stale key of a duplicate holds the book the
    matcher chose, and a duplicate can sit past `limit`, so the decision
    carries those keys itself rather than leaving them to the candidates."""
    import openlibrary.api.resolve as resolve_module

    top, other = _two_best_keys(client, a_title_with_multiple_candidates)
    _force_one_cluster(monkeypatch, {top, other}, {top: 1, other: 1000})
    fake = {top: ["OL1W", "OL2W"], other: ["OL3W"]}
    monkeypatch.setattr(
        resolve_module,
        "fetch_redirect_sources",
        lambda cur, paths, keys: {k: fake.get(k, []) for k in keys},
    )
    data = client.post(
        "/resolve", json={"title": a_title_with_multiple_candidates, "limit": 1}
    ).json()["data"]
    decision = data["decision"]
    assert decision["key"]["key"] == other
    assert decision["duplicates"] == [{"source": "openlibrary", "key": top}]
    assert decision["duplicate_redirect_sources"] == [
        {"source": "openlibrary", "key": "OL1W"},
        {"source": "openlibrary", "key": "OL2W"},
    ]
    assert [c["key"]["key"] for c in data["candidates"]] == [other]
    assert data["candidates"][0]["redirect_sources"] == [{"source": "openlibrary", "key": "OL3W"}]


def test_a_decision_with_no_duplicates_lists_no_duplicate_redirect_sources(
    client, a_redirect_target_with_a_resolvable_title
):
    title, _work_key = a_redirect_target_with_a_resolvable_title
    decision = client.post("/resolve", json={"title": title}).json()["data"]["decision"]
    assert decision["duplicates"] == []
    assert decision["duplicate_redirect_sources"] == []
