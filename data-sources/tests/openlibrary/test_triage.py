"""Sorting cases into ones a machine may settle and ones that need Shane.

Every threshold here was measured against the 204 labels he made by hand, not
chosen. When our identifiers reach exactly one OL work and that work is a
candidate, his label agreed 77 times in 79 -- and both misses were collections,
where he overrode the identifier for a reason no rule sees. When nothing of
ours reaches OL and blocking produced nothing, agreement was 38 in 57: the
other 19 books ARE in Open Library, under a translated or original title.

So the second bucket is not a slower version of the first. It is the bucket
this tool must refuse to answer.
"""

from __future__ import annotations

import pytest

from openlibrary.eval.triage import IdentifierReach, triage


def _reach(works=(), absent=0, orphaned=0) -> IdentifierReach:
    return IdentifierReach(works=frozenset(works), absent=absent, orphaned=orphaned)


def test_one_work_reached_and_shown_is_proposed_as_a_match():
    """no_popularity_signal-004 and 50 others: our ISBN lands on exactly one
    work, that work is on screen, and Shane said same_work every time."""
    t = triage(
        stratum="no_popularity_signal",
        candidate_keys=["OL2860956W", "OL41996W"],
        reach=_reach(works=["OL2860956W"]),
    )
    assert t.bucket == "decisive_match"
    assert t.work_key == "OL2860956W"
    assert t.identity_rule == "same_work"


def test_several_works_reached_goes_to_the_human():
    """Book #2582's nine identifiers span THREE works -- Collected Poems
    1934-1952, Daniel Jones's Poems, and Goodby's 2016 edition. Picking one is
    the labeller's call."""
    t = triage(
        stratum="shared_key_collision",
        candidate_keys=["OL18466944W", "OL1358968W", "OL21518117W"],
        reach=_reach(works=["OL18466944W", "OL1358968W", "OL21518117W"]),
    )
    assert t.bucket == "needs_human"
    assert "3" in t.reason


def test_nothing_reachable_is_never_called_a_no_match():
    """The expensive lesson: 19 of 57 such cases were books Shane FOUND in
    Open Library -- My Hero Academia under its english title, Vládce Klanů as
    Lord of the Clans. An automatic no_match here would have written 19 false
    negatives into the only ground truth this project gets."""
    t = triage(
        stratum="non_latin_title",
        candidate_keys=[],
        reach=_reach(absent=3),
    )
    assert t.bucket == "needs_human"
    assert t.work_key is None


def test_a_collection_is_never_settled_by_its_identifier():
    """Both of Rule A's measured failures were collections:
    anthology_or_collection-002, where the identifier pointed at OL15206548W
    and Shane chose OL31748277W because its subtitle enumerated exactly the
    plays his edition holds. high_frequency_title is 28 more of the same shape,
    so the rule does not get extrapolated into it."""
    t = triage(
        stratum="high_frequency_title",
        candidate_keys=["OL15206548W"],
        reach=_reach(works=["OL15206548W"]),
    )
    assert t.bucket == "needs_human"


def test_an_identifier_pointing_off_the_candidate_list_goes_to_the_human():
    """von Baer's isbn belongs to a different book entirely (OL12708683M, 'Sag
    nicht Ja, wenn Du Nein sagen willst'). A reached work that blocking never
    surfaced is a signal something is wrong, not a match."""
    t = triage(
        stratum="stale_ol_key",
        candidate_keys=["OL4328119W"],
        reach=_reach(works=["OL12708683W"]),
    )
    assert t.bucket == "needs_human"


def test_two_works_reached_is_already_too_many():
    """The boundary, not a comfortable case above it. isbn_reuse is built from
    ISBNs that land on more than one work, and two is the common count -- a
    rule that only balked at three would auto-answer most of that stratum."""
    t = triage(
        stratum="isbn_reuse",
        candidate_keys=["OL455827W", "OL15838248W"],
        reach=_reach(works=["OL455827W", "OL15838248W"]),
    )
    assert t.bucket == "needs_human"
    assert "2" in t.reason


def test_candidates_with_no_identifier_support_go_to_the_human():
    """Both this and the nothing-at-all case return needs_human, so the bucket
    alone cannot distinguish them -- and the difference is the whole point.
    Here Shane chooses between works already on screen; there he has to go and
    search. The reason has to say which."""
    t = triage(
        stratum="author_less_work",
        candidate_keys=["OL1W", "OL2W"],
        reach=_reach(absent=1),
    )
    assert t.bucket == "needs_human"
    assert "2 candidates" in t.reason
    assert "nothing reachable" not in t.reason


@pytest.mark.parametrize("stratum", ["anthology_or_collection", "high_frequency_title"])
def test_the_excluded_strata_are_the_ones_with_measured_failures(stratum):
    t = triage(stratum=stratum, candidate_keys=["OL9W"], reach=_reach(works=["OL9W"]))
    assert t.bucket == "needs_human"


def _entry(case_id, stratum, candidates, generated=(), **ids):
    from openlibrary.eval.build_pool import GeneratedCandidateKey, PoolCandidate, PoolEntry
    from openlibrary.eval.schema import EvalBook

    return PoolEntry(
        case_id=case_id,
        stratum=stratum,
        book=EvalBook(book_id=1, title="x", author_names=["y"], **ids),
        candidates=[PoolCandidate(work_key=k, rules=["identifier"]) for k in candidates],
        all_generated=[GeneratedCandidateKey(work_key=k, rules=["title_fp"]) for k in generated],
    )


def test_reach_sees_works_the_candidate_list_does_not(fixture_artifact):
    """The point of resolving identifiers globally rather than
    against the
    candidates. In the corpus `080782156X` sits on OL108593W AND OL269642W; a
    case showing only the first would look like a clean one-work match while
    the ISBN is in fact ambiguous. `label.fetch_identifier_hits` cannot see
    that, because it joins on the candidate key."""
    from openlibrary.eval.triage import fetch_identifier_reach

    entry = _entry("wide", "isbn_reuse", ["OL108593W"], isbn10=["080782156X"])

    reach = fetch_identifier_reach(fixture_artifact.root, fixture_artifact.dump_date, [entry])

    assert reach["wide"].works == frozenset({"OL108593W", "OL269642W"})


def test_a_number_open_library_never_heard_of_is_counted_absent(fixture_artifact):
    """Absent and orphaned route differently: absent means no such book,
    orphaned means Open Library holds it on an edition with no work key --
    1,947,922 such editions exist and blocking cannot see one of them."""
    from openlibrary.eval.triage import fetch_identifier_reach

    entry = _entry("gone", "easy_baseline", [], isbn13=["9789999999999"])

    reach = fetch_identifier_reach(fixture_artifact.root, fixture_artifact.dump_date, [entry])

    assert reach["gone"].works == frozenset()
    assert reach["gone"].absent > 0


def test_a_missing_artifact_returns_none_rather_than_raising(tmp_path):
    from openlibrary.eval.triage import fetch_identifier_reach

    assert fetch_identifier_reach(tmp_path, "2026-07-31", []) is None


def test_a_key_blocking_produced_outside_the_top_twenty_still_counts_as_shown():
    """`candidates` is capped at 20 for terminal rendering. Judging "blocking
    never surfaced this" against the capped list would report a correct
    identifier as a wrong one."""
    from openlibrary.eval.triage import blocking_produced

    entry = _entry("c", "easy_baseline", ["OL1W"], generated=["OL1W", "OL2W"])

    assert blocking_produced(entry) == {"OL1W", "OL2W"}


def _cand(work_key="OL9W", title=None, authors=(), declared=None, min_ed=None, modal=None):
    from openlibrary.eval.build_pool import PoolCandidate

    return PoolCandidate(
        work_key=work_key,
        rules=["identifier"],
        title=title,
        author_names=list(authors),
        declared_year=declared,
        min_edition_year=min_ed,
        modal_edition_year=modal,
    )


def _book(title="x", authors=("y",), year=None):
    from openlibrary.eval.schema import EvalBook

    return EvalBook(book_id=1, title=title, author_names=list(authors), first_published_year=year)


def test_a_shared_author_corroborates_the_identifier():
    from openlibrary.eval.triage import corroborated

    assert corroborated(_book(authors=["Fabian Nicieza"]), _cand(authors=["Fabian Nicieza"]))


def test_a_name_written_in_the_other_order_still_corroborates():
    """degenerate_title-005: our `Feng Jicai` against Open Library's
    `jicai feng`. The same person, and the reason this reuses the audit's
    classifier instead of comparing sets of fingerprints."""
    from openlibrary.eval.triage import corroborated

    assert corroborated(_book(authors=["Feng Jicai"]), _cand(authors=["Jicai Feng"]))


def test_a_shared_surname_alone_does_not_corroborate():
    """`surname_collision` is the class that means WRONG PERSON 10,607 times
    over. Accepting it here would corroborate exactly the failure this check
    exists to catch."""
    from openlibrary.eval.triage import corroborated

    assert not corroborated(_book(authors=["Paul Auster"]), _cand(authors=["Sara Auster"]))


def test_the_year_falling_inside_the_editions_corroborates():
    from openlibrary.eval.triage import corroborated

    assert corroborated(_book(year=1954), _cand(min_ed=1952, modal=1957))


def test_nothing_in_common_is_not_corroborated():
    """author_less_work-010: our 1960 Blackbook guide by Thomas E. Hudgeons Jr
    against Open Library's 2011 `official 2012 blackbook` by Marc Hudgeons.
    Different year, different person, and only the identifier joining them."""
    from openlibrary.eval.triage import corroborated

    ours = _book(
        title="The Official Blackbook Price Guide To United States Coins",
        authors=["Thomas E. Hudgeons Jr."],
        year=1960,
    )
    theirs = _cand(
        title="The official 2012 blackbook price guide to United States coins",
        authors=["Marc Hudgeons"],
        min_ed=2011,
        modal=2011,
    )
    assert not corroborated(ours, theirs)


def test_an_uncorroborated_identifier_goes_to_the_human():
    """pseudonym_or_alt_name-025: our whole `Story of the Stone` (Cao Xueqin,
    1791) against `The Debt of Tears`, which is VOLUME 4 of it, translated by
    John Minford in 1982. The ISBN really does sit on that work; it is still
    not the book our row names."""
    from openlibrary.eval.triage import triage

    t = triage(
        stratum="pseudonym_or_alt_name",
        candidate_keys=["OL14960181W"],
        reach=IdentifierReach(works=frozenset({"OL14960181W"})),
        corroborates=False,
    )
    assert t.bucket == "needs_human"
    assert "corrobor" in t.reason
