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

from common.normalize import MIN_BLOCKING_FP_LENGTH
from openlibrary.matcher.blocking import (
    MAX_CANDIDATES_PER_RULE,
    MAX_SHELF_SIZE,
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
        f"SELECT work_key FROM '{fixture_artifact.table('works')}' ORDER BY work_key LIMIT 1"
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
        GROUP BY value ORDER BY 2 DESC, value LIMIT 1
        """
    ).fetchone()
    assert row is not None, "corpus lost the isbn13 identifiers this test needs"
    value, distinct_works = row
    assert distinct_works > 1, "corpus lost the multi-work isbn13 shape this test needs"
    result = generate_candidates(con, fixture_artifact, BlockingQuery(title="x", isbn13=[value]))
    # An evidence table: the caller sees the ambiguity rather than a guess.
    assert len(result.candidates) == distinct_works


def test_title_and_author_together_fire_the_precision_rule(con, fixture_artifact):
    # `length(w.title_fp) >= MIN_BLOCKING_FP_LENGTH`, not just `<> ''`: a
    # too-short fingerprint (e.g. "Zen") never enters `variants` and could
    # never fire rule 4/author_title_fp regardless of the author (ruling R43).
    row = con.execute(
        f"""
        SELECT w.title, a.name FROM '{fixture_artifact.table("works")}' w
        JOIN '{fixture_artifact.table("work_authors")}' wa USING (work_key)
        JOIN '{fixture_artifact.table("authors")}' a USING (author_key)
        WHERE length(w.title_fp) >= {MIN_BLOCKING_FP_LENGTH} AND a.name_fp <> ''
        ORDER BY w.work_key, a.author_key LIMIT 1
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
        WHERE a.name_fp <> '' GROUP BY a.name HAVING count(*) >= 1
        ORDER BY a.name LIMIT 1
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
        WHERE title_fp_freq > {MAX_TITLE_FP_FREQ}
        ORDER BY work_key LIMIT 1
        """
    ).fetchone()
    assert row is not None, "corpus lost the freq > MAX_TITLE_FP_FREQ shared-title block"
    (title,) = row
    result = generate_candidates(con, fixture_artifact, BlockingQuery(title=title))
    assert "title_fp" in result.guards_tripped
    assert all("title_fp" not in rules for rules in result.candidates.values())


def test_a_suppressed_common_title_does_not_fall_through_to_trigram(con, fixture_artifact):
    """Ruling R39: a title rule 4 suppresses for frequency HAD exact hits, so
    rule 6 must not resurrect them under a fuzzy label just because nothing
    else fired -- that would silently defeat the guard rule 4 just tripped."""
    row = con.execute(
        f"""
        SELECT title FROM '{fixture_artifact.table("works")}'
        WHERE title_fp_freq > {MAX_TITLE_FP_FREQ}
        ORDER BY work_key LIMIT 1
        """
    ).fetchone()
    assert row is not None, "corpus lost the freq > MAX_TITLE_FP_FREQ shared-title block"
    (title,) = row
    result = generate_candidates(con, fixture_artifact, BlockingQuery(title=title))
    assert result.candidates == {}
    assert all("trigram" not in rules for rules in result.candidates.values())


def test_a_genuinely_short_title_still_reaches_trigram(con, fixture_artifact):
    """Amended ruling R39: rule 4's "title_fp" guard also trips for a title
    whose every fingerprint variant is shorter than MIN_BLOCKING_FP_LENGTH --
    a case with ZERO exact hits, unlike a suppressed common title. That case
    must still reach rule 6; testing `guards_tripped` membership (the first,
    regressed version of this fix) wrongly blocked it too. OL10266809W
    ("Zen") is one of five such works in the corpus."""
    result = generate_candidates(con, fixture_artifact, BlockingQuery(title="Zen"))
    assert "title_fp" in result.guards_tripped
    assert "OL10266809W" in result.candidates
    assert "trigram" in result.candidates["OL10266809W"]


def test_no_rule_ever_returns_more_than_the_cap(con, fixture_artifact):
    result = generate_candidates(
        con, fixture_artifact, BlockingQuery(title="the", author_names=["a"])
    )
    for rule in RULES:
        count = sum(1 for rules in result.candidates.values() if rule in rules)
        # Rule 5's own cap is MAX_SHELF_SIZE, not MAX_CANDIDATES_PER_RULE: once
        # an author resolves, the scorer is meant to read the whole shelf.
        cap = MAX_SHELF_SIZE if rule == "author_shelf" else MAX_CANDIDATES_PER_RULE
        assert count <= cap


def test_an_author_resolution_failure_does_not_disable_the_title_rules(con, fixture_artifact):
    # `length(title_fp) >= MIN_BLOCKING_FP_LENGTH`, not just `<> ''`: a
    # too-short fingerprint (e.g. "Zen") never enters `variants` and could
    # never fire rule 4 regardless of the author (ruling R43).
    row = con.execute(
        f"SELECT title FROM '{fixture_artifact.table('works')}' "
        f"WHERE length(title_fp) >= {MIN_BLOCKING_FP_LENGTH} AND title_fp_freq = 1 "
        "ORDER BY work_key LIMIT 1"
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
