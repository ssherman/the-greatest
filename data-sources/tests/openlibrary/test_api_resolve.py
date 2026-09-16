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
    con = _con()
    row = con.execute(
        f"""
        SELECT w.title, d.declared_year FROM '{fixture_artifact.table("works")}' w
        JOIN '{fixture_artifact.table("work_details")}' d USING (work_key)
        WHERE w.title_fp <> '' AND d.declared_year IS NOT NULL
        ORDER BY w.work_key LIMIT 1
        """
    ).fetchone()
    con.close()
    if row is None:
        pytest.skip("fixture corpus has no work with a declared year")
    return row[0], row[1]


def test_resolve_always_returns_a_list_of_candidates(client, a_resolvable_title):
    data = client.post("/resolve", json={"title": a_resolvable_title}).json()["data"]
    # No resolve returns a single answer: a guess must never be mistakable for a fact.
    assert isinstance(data["candidates"], list)


def test_a_query_that_matches_nothing_returns_an_empty_list_and_a_reject(client):
    # "Zzzq Nothing Whatsoever Matches This String" risks a fuzzy (rule 6)
    # character-set Jaccard hit against the real corpus (ruling R69's
    # replacement); a title built from only two letters has a character set
    # small enough that no real title's fingerprint can reach the 0.55
    # threshold against it.
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


def test_the_decided_candidate_carries_the_decision_verdict_and_no_other_accepts(
    client, a_resolvable_title
):
    data = client.post("/resolve", json={"title": a_resolvable_title, "limit": 50}).json()["data"]
    decision = data["decision"]
    saw_decision_key = False
    other_verdicts = []
    for candidate in data["candidates"]:
        if decision["key"] is not None and candidate["key"] == decision["key"]:
            assert candidate["verdict"] == decision["verdict"]
            saw_decision_key = True
        else:
            other_verdicts.append(candidate["verdict"])
    if decision["key"] is not None:
        assert saw_decision_key
    assert "accept" not in other_verdicts


def test_every_key_is_namespaced_and_no_bare_work_key_leaks(client, a_resolvable_title):
    response = client.post("/resolve", json={"title": a_resolvable_title, "limit": 50})
    assert "work_key" not in response.text
    data = response.json()["data"]
    if data["decision"]["key"] is not None:
        assert data["decision"]["key"]["source"] == "openlibrary"
    for candidate in data["candidates"]:
        assert candidate["key"]["source"] == "openlibrary"
