"""Tests for stage 1 candidate generation (blocking).

Uses the session-scoped `fixture_artifact` (see tests/conftest.py) rather than
building a fresh artifact per test. Discovery queries ASSERT the row they find
exists rather than `pytest.skip`-ing when it doesn't: a test that can skip
silently stops testing the thing it names, and every shape these tests need is
known to be present in the committed fixture corpus (see
tests/fixtures/test_fixture_corpus.py).
"""

from __future__ import annotations

import pytest

from openlibrary.matcher.blocking import (
    MAX_CANDIDATES_PER_RULE,
    MAX_TITLE_FP_FREQ,
    RULES,
    BlockingQuery,
    generate_candidates,
)
from openlibrary.pipeline.duck import connect

# Pinned to shapes the committed fixture corpus is known to hold:
#   OL15331408W -> OL3809593W    the one resolvable work redirect
#   OL26204513W -> OL16808392W   a dangling redirect (terminal absent from works)
RESOLVABLE_SOURCE = "OL15331408W"
RESOLVABLE_TERMINAL = "OL3809593W"
DANGLING_SOURCE = "OL26204513W"


@pytest.fixture()
def con(fixture_artifact):
    connection = connect(fixture_artifact, memory_limit="1GB")
    yield connection
    connection.close()


def test_all_six_rules_are_declared():
    assert RULES == (
        "identifier",
        "existing_key",
        "author_title_fp",
        "title_fp",
        "author_shelf",
        "trigram",
    )


def test_an_existing_key_produces_a_candidate(con, fixture_artifact):
    (key,) = con.execute(
        f"SELECT work_key FROM '{fixture_artifact.table('works')}' LIMIT 1"
    ).fetchone()
    result = generate_candidates(
        con, fixture_artifact, BlockingQuery(title="x", existing_ol_key=key)
    )
    assert key in result.candidates
    assert "existing_key" in result.candidates[key]


def test_a_stale_existing_key_resolves_through_redirects(con, fixture_artifact):
    result = generate_candidates(
        con, fixture_artifact, BlockingQuery(title="x", existing_ol_key=RESOLVABLE_SOURCE)
    )
    assert RESOLVABLE_TERMINAL in result.candidates
    assert "existing_key" in result.candidates[RESOLVABLE_TERMINAL]


def test_a_dangling_stored_key_yields_no_existing_key_candidate_or_guard(con, fixture_artifact):
    """The redirect resolves to a terminal, but that terminal is not itself a
    work -- so rule 2 must produce nothing, silently, rather than a candidate
    for a work that does not exist."""
    result = generate_candidates(
        con,
        fixture_artifact,
        BlockingQuery(
            title="a title that will not match anything at all", existing_ol_key=DANGLING_SOURCE
        ),
    )
    assert all("existing_key" not in rules for rules in result.candidates.values())
    assert "existing_key" not in result.guards_tripped


def test_an_identifier_produces_a_candidate_and_may_produce_several(con, fixture_artifact):
    row = con.execute(
        f"""
        SELECT value, count(DISTINCT work_key) FROM '{fixture_artifact.table("identifiers")}'
        WHERE id_type = 'isbn13' AND work_key IS NOT NULL
        GROUP BY value ORDER BY 2 DESC LIMIT 1
        """
    ).fetchone()
    assert row is not None, "corpus lost the isbn13 identifiers this test needs"
    value, distinct_works = row
    assert distinct_works > 1, "corpus lost the multi-work isbn13 shape this test needs"
    result = generate_candidates(con, fixture_artifact, BlockingQuery(title="x", isbn13=[value]))
    # An evidence table: the caller sees the ambiguity rather than a guess.
    assert len(result.candidates) == distinct_works


def test_title_and_author_together_fire_the_precision_rule(con, fixture_artifact):
    row = con.execute(
        f"""
        SELECT w.title, a.name FROM '{fixture_artifact.table("works")}' w
        JOIN '{fixture_artifact.table("work_authors")}' wa USING (work_key)
        JOIN '{fixture_artifact.table("authors")}' a USING (author_key)
        WHERE w.title_fp <> '' AND a.name_fp <> '' LIMIT 1
        """
    ).fetchone()
    assert row is not None, "corpus lost a work with a fingerprintable title and author"
    title, author = row
    result = generate_candidates(
        con, fixture_artifact, BlockingQuery(title=title, author_names=[author])
    )
    fired = {rule for rules in result.candidates.values() for rule in rules}
    assert "author_title_fp" in fired


def test_the_author_shelf_rule_fires_without_needing_a_title_match(con, fixture_artifact):
    row = con.execute(
        f"""
        SELECT a.name FROM '{fixture_artifact.table("authors")}' a
        JOIN '{fixture_artifact.table("work_authors")}' wa USING (author_key)
        WHERE a.name_fp <> '' GROUP BY a.name HAVING count(*) >= 1 LIMIT 1
        """
    ).fetchone()
    assert row is not None, "corpus lost an author with works"
    (author,) = row
    result = generate_candidates(
        con,
        fixture_artifact,
        BlockingQuery(title="a title that matches nothing at all", author_names=[author]),
    )
    fired = {rule for rules in result.candidates.values() for rule in rules}
    assert "author_shelf" in fired


def test_a_degenerate_title_trips_a_guard_instead_of_exploding(con, fixture_artifact):
    result = generate_candidates(con, fixture_artifact, BlockingQuery(title="!!!"))
    # "!!!" fingerprints to the empty string. It must produce a visible gap.
    assert "title_fp" in result.guards_tripped
    assert all("title_fp" not in rules for rules in result.candidates.values())


def test_a_high_frequency_title_trips_the_guard_and_does_not_fire(con, fixture_artifact):
    """`title_fp_freq > MAX_TITLE_FP_FREQ` (the corpus's synthetic 51-work
    "Selected Poems" block) must be suppressed with a visible guard, not
    silently dropped -- ruling R32."""
    row = con.execute(
        f"""
        SELECT title FROM '{fixture_artifact.table("works")}'
        WHERE title_fp_freq > {MAX_TITLE_FP_FREQ} LIMIT 1
        """
    ).fetchone()
    assert row is not None, "corpus lost the freq > MAX_TITLE_FP_FREQ shared-title block"
    (title,) = row
    result = generate_candidates(con, fixture_artifact, BlockingQuery(title=title))
    assert "title_fp" in result.guards_tripped
    assert all("title_fp" not in rules for rules in result.candidates.values())


def test_no_rule_ever_returns_more_than_the_cap(con, fixture_artifact):
    result = generate_candidates(
        con, fixture_artifact, BlockingQuery(title="the", author_names=["a"])
    )
    for rule in RULES:
        count = sum(1 for rules in result.candidates.values() if rule in rules)
        assert count <= MAX_CANDIDATES_PER_RULE


def test_an_author_resolution_failure_does_not_disable_the_title_rules(con, fixture_artifact):
    row = con.execute(
        f"SELECT title FROM '{fixture_artifact.table('works')}' "
        "WHERE title_fp <> '' AND title_fp_freq = 1 LIMIT 1"
    ).fetchone()
    assert row is not None, "corpus lost a uniquely fingerprinted title"
    result = generate_candidates(
        con,
        fixture_artifact,
        BlockingQuery(title=row[0], author_names=["No Such Author Exists Anywhere"]),
    )
    fired = {rule for rules in result.candidates.values() for rule in rules}
    # Author blocking is a precision rule, not a gate. Rules 1, 4 and 6 still fire.
    assert "title_fp" in fired
