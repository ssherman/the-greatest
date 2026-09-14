"""Tests for stage 1 candidate generation (blocking).

Uses the session-scoped `fixture_artifact` (see tests/conftest.py) rather than
building a fresh artifact per test. Discovery queries ASSERT the row they find
exists rather than `pytest.skip`-ing when it doesn't: a test that can skip
silently stops testing the thing it names, and every shape these tests need is
known to be present in the committed fixture corpus (see
tests/fixtures/test_fixture_corpus.py).
"""

from __future__ import annotations

import contextlib
import shutil

import pytest

from common.normalize import MIN_BLOCKING_FP_LENGTH
from openlibrary.matcher.blocking import (
    MAX_CANDIDATES_PER_RULE,
    MAX_SHELF_SIZE,
    MAX_TITLE_FP_FREQ,
    RULES,
    BlockingQuery,
    BlockingResult,
    generate_candidates,
)
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import TABLES, ArtifactPaths

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


# Shapes the committed corpus cannot hold without breaking the corpus tests
# that pin it: an identifier whose edition still points at a STALE work key
# (a redirect source), one pointing at a key that is in no table at all, and
# an author with more works than MAX_SHELF_SIZE. The real 2026-07-31 artifact
# has all three (R41: 270 stale identifier keys, 294 absent ones; R59: the
# Agatha Christie shelf is 1,226 works). This derives a second artifact from
# the fixture one -- every table copied, two rewritten with synthetic rows --
# so the code paths those shapes exercise are tested against real Parquet,
# not asserted from the SQL text.
STALE_ISBN13 = "9780000000002"
ABSENT_ISBN13 = "9780000000019"
ABSENT_WORK_KEY = "OL999999999W"
BIG_SHELF_AUTHOR = "Synthetic Shelf Author"
BIG_SHELF_AUTHOR_KEY = "OL999999999A"


@pytest.fixture(scope="module")
def derived_artifact(fixture_artifact, tmp_path_factory) -> ArtifactPaths:
    root = tmp_path_factory.mktemp("ol-artifact-derived")
    derived = ArtifactPaths(root=root, dump_date=fixture_artifact.dump_date)
    derived.ensure()
    for table in TABLES:
        shutil.copyfile(fixture_artifact.table(table), derived.table(table))

    con = connect(derived, memory_limit="1GB")
    with contextlib.closing(con):
        # Two identifier rows on one edition: one whose work_key is the
        # corpus's resolvable redirect SOURCE, one whose work_key exists
        # nowhere.
        con.execute(
            f"""
            COPY (
              SELECT * FROM '{fixture_artifact.table("identifiers")}'
              UNION ALL
              SELECT 'isbn13', '{STALE_ISBN13}', 'OL999999901M', '{RESOLVABLE_SOURCE}', true
              UNION ALL
              SELECT 'isbn13', '{ABSENT_ISBN13}', 'OL999999902M', '{ABSENT_WORK_KEY}', true
            ) TO '{derived.table("identifiers")}' (FORMAT parquet)
            """
        )
        # One author with MAX_SHELF_SIZE + 1 works. Rule 5 counts
        # `work_authors` rows without joining `works`, so the keys need not
        # exist -- and they must not, or they would fire other rules.
        con.execute(
            f"""
            COPY (
              SELECT * FROM '{fixture_artifact.table("author_names")}'
              UNION ALL
              SELECT '{BIG_SHELF_AUTHOR_KEY}', '{BIG_SHELF_AUTHOR}',
                     '{BIG_SHELF_AUTHOR.lower()}', 'primary'
            ) TO '{derived.table("author_names")}' (FORMAT parquet)
            """
        )
        con.execute(
            f"""
            COPY (
              SELECT * FROM '{fixture_artifact.table("work_authors")}'
              UNION ALL
              SELECT 'OLSYNTH' || i || 'W', '{BIG_SHELF_AUTHOR_KEY}', CAST(1 AS SMALLINT)
              FROM range({MAX_SHELF_SIZE + 1}) t(i)
            ) TO '{derived.table("work_authors")}' (FORMAT parquet)
            """
        )
    return derived


@pytest.fixture()
def derived_con(derived_artifact):
    connection = connect(derived_artifact, memory_limit="1GB")
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
    # ...but NOT a volume guard (R59): nothing was found and refused, there
    # was simply nothing to look up. With no other rule firing this must
    # still read as "not found" downstream.
    assert result.volume_guards_tripped == []
    assert all("title_fp" not in rules for rules in result.candidates.values())


def test_volume_guards_are_always_a_subset_of_all_guards(con, fixture_artifact):
    for title in ("!!!", "Zen", "Selected Poems", "a title that matches nothing at all"):
        result = generate_candidates(con, fixture_artifact, BlockingQuery(title=title))
        assert set(result.volume_guards_tripped) <= set(result.guards_tripped), title


def test_identifier_hits_is_the_set_of_works_reached_by_rule_one():
    result = BlockingResult(
        candidates={
            "OL1W": ["identifier", "title_fp"],
            "OL2W": ["identifier"],
            "OL3W": ["title_fp", "author_shelf"],
        }
    )
    assert result.identifier_hits == frozenset({"OL1W", "OL2W"})
    assert BlockingResult().identifier_hits == frozenset()


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
    # R59: 51 works DID carry this title -- the search was refused for
    # volume, which is what turns a zero-candidate result into an abstain
    # rather than a reject downstream.
    assert "title_fp" in result.volume_guards_tripped
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


# ---------------------------------------------------------------------------
# Shapes only the derived artifact holds (see `derived_artifact`).
# ---------------------------------------------------------------------------


def test_rule_one_resolves_a_stale_identifier_work_key_through_redirects(
    derived_con, derived_artifact
):
    """R41: the edition carrying STALE_ISBN13 still names the redirect SOURCE.
    Rule 1 must return the terminal -- the work that actually exists -- under
    the identifier rule, and never the stale key: a stale key in
    `identifier_hits` turns the true work into an identifier CONFLICT (R35)."""
    result = generate_candidates(
        derived_con, derived_artifact, BlockingQuery(title="x", isbn13=[STALE_ISBN13])
    )
    assert RESOLVABLE_TERMINAL in result.candidates
    assert "identifier" in result.candidates[RESOLVABLE_TERMINAL]
    assert RESOLVABLE_SOURCE not in result.candidates
    assert result.identifier_hits == frozenset({RESOLVABLE_TERMINAL})


def test_rule_one_drops_an_identifier_work_key_absent_from_works(derived_con, derived_artifact):
    """R41's other half: a key that is neither a work nor a redirect source is
    dropped, silently and without a guard -- there is nothing to fetch and
    nothing was refused."""
    result = generate_candidates(
        derived_con, derived_artifact, BlockingQuery(title="x", isbn13=[ABSENT_ISBN13])
    )
    assert ABSENT_WORK_KEY not in result.candidates
    assert result.identifier_hits == frozenset()
    assert "identifier" not in result.guards_tripped


def test_rule_one_never_returns_a_key_absent_from_works(con, fixture_artifact):
    """Every isbn13 the corpus attaches to more than one work: each key rule 1
    returns must be a real row in `works`."""
    values = [
        value
        for (value,) in con.execute(
            f"""
            SELECT value FROM '{fixture_artifact.table("identifiers")}'
            WHERE id_type = 'isbn13' AND work_key IS NOT NULL
            GROUP BY value HAVING count(DISTINCT work_key) > 1
            ORDER BY value
            """
        ).fetchall()
    ]
    assert values, "corpus lost the multi-work isbn13 shape this test needs"
    returned = set()
    for value in values:
        result = generate_candidates(
            con, fixture_artifact, BlockingQuery(title="x", isbn13=[value])
        )
        returned |= result.identifier_hits
    assert returned, "rule 1 returned nothing for any multi-work isbn13"
    for key in sorted(returned):
        (exists,) = con.execute(
            f"SELECT count(*) FROM '{fixture_artifact.table('works')}' WHERE work_key = ?", [key]
        ).fetchone()
        assert exists == 1, f"rule 1 returned {key}, which is not in works"


def test_an_oversized_author_shelf_is_a_volume_guard_with_no_candidates(
    derived_con, derived_artifact
):
    """R59's motivating case (degenerate_title-014): a Cyrillic title
    fingerprints to the empty string, so rules 3, 4 and 6 have nothing to
    look up; the author resolves but the shelf is over MAX_SHELF_SIZE.
    `guards_tripped` names both reasons; `volume_guards_tripped` names only
    the shelf -- the one that means something was found and refused -- so
    the decider can abstain instead of recording "not in Open Library"."""
    result = generate_candidates(
        derived_con,
        derived_artifact,
        BlockingQuery(title="Убийство в Восточном экспрессе", author_names=[BIG_SHELF_AUTHOR]),
    )
    assert result.candidates == {}
    assert set(result.guards_tripped) == {"title_fp", "author_shelf"}
    assert result.volume_guards_tripped == ["author_shelf"]
