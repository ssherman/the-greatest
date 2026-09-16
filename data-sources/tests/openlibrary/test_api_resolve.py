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


def test_candidates_are_ordered_by_score_descending(client, a_resolvable_title):
    scores = [
        c["score"]
        for c in client.post("/resolve", json={"title": a_resolvable_title}).json()["data"][
            "candidates"
        ]
    ]
    assert scores == sorted(scores, reverse=True)


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
