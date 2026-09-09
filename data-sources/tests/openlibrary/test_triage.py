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
        corroborates=True,
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


def test_a_matching_year_alone_does_not_corroborate():
    """This limb existed and shipped a false merge with it.

    Book #36129, Pamela Anderson's `I Love You` (2024), carries isbn13
    9780316573481. Open Library really does hold that number -- on
    OL38014589W, `New Cookbook by Paul Anthony`, three editions, all 2024,
    Little Brown. Author `unrelated`, no title overlap, and the year limb
    said 2024 <= 2024 <= 2024, so the tool proposed Pamela Anderson's memoir
    as the same work as a Paul Anthony cookbook and overrode her plausible
    stored key OL28844458W.

    With one distinct year the check degenerates to "published the same
    year", which is not evidence of anything. Two of 73 proposals rested on
    it and one was that."""
    from openlibrary.eval.triage import corroborated

    ours = _book(title="I Love You", authors=["Pamela Anderson"], year=2024)
    theirs = _cand(
        title="New Cookbook by Paul Anthony", authors=["Paul Anthony"], min_ed=2024, modal=2024
    )
    assert not corroborated(ours, theirs)


def test_a_title_too_short_to_block_on_cannot_corroborate():
    """non_latin_title-013: our 熱帯魚は雪に焦がれる 1 fingerprints to
    `1 nettaigyo wa yuki ni kogareru 1`, Open Library's work to `1`. The
    substring test passed on a single character -- one that 1,675 OL works
    share. MIN_BLOCKING_FP_LENGTH already governs this everywhere else in the
    project; it was missing only here."""
    from openlibrary.eval.triage import corroborated

    ours = _book(
        title="熱帯魚は雪に焦がれる 1 [Nettaigyo Wa Yuki Ni Kogareru 1]", authors=["Makoto Hagino"]
    )
    assert not corroborated(ours, _cand(title="1", authors=[]))


def test_two_identically_short_titles_do_not_corroborate_each_other():
    """The length floor and the overlap ratio catch different things, and
    without this only the ratio was tested. `It` against `It` is a perfect
    containment at ratio 1.0 on two characters -- and 613 OL works fingerprint
    to `i`, 1,488 to `2`. MIN_BLOCKING_FP_LENGTH is what blocking uses to
    refuse exactly this, so corroboration uses it too."""
    from openlibrary.eval.triage import corroborated

    assert not corroborated(_book(title="It"), _cand(title="It"))


def test_a_title_that_is_a_small_fraction_of_the_other_does_not_corroborate():
    """shared_key_collision-023: `america` inside `america the book`. Long
    enough to block on, and still two different books."""
    from openlibrary.eval.triage import corroborated

    assert not corroborated(_book(title="America"), _cand(title="America the Book"))


def test_a_dropped_leading_article_still_corroborates():
    """pseudonym_or_alt_name-029: `the women could fly` against
    `women could fly`. The containment test has to survive this or it stops
    being useful at all."""
    from openlibrary.eval.triage import corroborated

    assert corroborated(_book(title="The Women Could Fly"), _cand(title="Women Could Fly"))


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


def test_corroboration_defaults_to_refusing():
    """Fail closed. The default is what a future caller gets when it forgets
    the argument, and the cost of the two mistakes is not symmetric: a missed
    proposal costs Shane one case to read, an unchecked one writes a false
    merge into the ground truth."""
    from openlibrary.eval.triage import triage

    t = triage(stratum="easy_baseline", candidate_keys=["OL9W"], reach=_reach(works=["OL9W"]))
    assert t.bucket == "needs_human"


def _pool_file(tmp_path, entries):
    import json

    p = tmp_path / "pool.jsonl"
    p.write_text(
        "\n".join(json.dumps(e.model_dump(mode="json"), ensure_ascii=False) for e in entries),
        encoding="utf-8",
    )
    return p


def test_the_cli_refuses_to_write_over_the_labels_file(tmp_path, fixture_artifact):
    """cases/proposed.jsonl and cases/labels.jsonl sit in the same directory
    and share an extension. `proposed.open("w")` truncates. One mistyped flag
    would destroy 204 labels that took days and cannot be regenerated, with no
    error and nothing to restore from."""
    import typer

    from openlibrary.eval.triage import main

    labels = tmp_path / "labels.jsonl"
    labels.write_text("", encoding="utf-8")
    pool = _pool_file(
        tmp_path, [_entry("c", "easy_baseline", ["OL108593W"], isbn10=["080782156X"])]
    )

    # A working artifact, so the only thing that can stop this is the guard.
    kwargs = dict(
        pool=pool,
        labels=labels,
        report=tmp_path / "r.md",
        dump_date=fixture_artifact.dump_date,
        root=fixture_artifact.root,
    )
    main(proposed=tmp_path / "fine.jsonl", **kwargs)  # the same call without the collision works

    with pytest.raises(typer.Exit):
        main(proposed=labels, **kwargs)
    with pytest.raises(typer.Exit):
        main(proposed=tmp_path / "ok.jsonl", **{**kwargs, "report": labels})


def test_the_cli_never_touches_the_labels_file(tmp_path, fixture_artifact):
    """The one hard requirement. Mutating `proposed.open("w")` into
    `labels.open("a")` left the whole suite green, so nothing was actually
    checking it."""
    from openlibrary.eval.triage import main

    labels = tmp_path / "labels.jsonl"
    labels.write_text("", encoding="utf-8")
    before = labels.read_bytes()
    entry = _entry("c", "easy_baseline", ["OL108593W"], isbn10=["080782156X"])
    proposed = tmp_path / "proposed.jsonl"

    main(
        pool=_pool_file(tmp_path, [entry]),
        labels=labels,
        proposed=proposed,
        report=tmp_path / "r.md",
        dump_date=fixture_artifact.dump_date,
        root=fixture_artifact.root,
    )

    assert labels.read_bytes() == before
    assert proposed.exists()


def _proposable(case_id="c"):
    """A case the tool SHOULD propose: isbn10 1555849091 reaches exactly one
    work in the fixture corpus (OL8331643W, `Blood River` by Tim Butcher) and
    the author agrees, so corroboration holds."""
    entry = _entry(case_id, "easy_baseline", ["OL8331643W"], isbn10=["1555849091"])
    entry.book.title = "Blood River"
    entry.book.author_names = ["Tim Butcher"]
    entry.candidates[0].title = "Blood River"
    entry.candidates[0].author_names = ["Tim Butcher"]
    return entry


def test_a_written_proposal_is_stamped_as_machine_made(tmp_path, fixture_artifact):
    """Flipping labeled_by to "human" in the writer killed no test: only the
    schema DEFAULT was covered, never what this tool stamps. The first version
    of this test asserted inside a `for` over an empty list and so proved
    nothing -- hence the explicit count."""
    import json

    from openlibrary.eval.schema import EvalCase
    from openlibrary.eval.triage import main

    proposed = tmp_path / "proposed.jsonl"
    main(
        pool=_pool_file(tmp_path, [_proposable()]),
        labels=tmp_path / "labels.jsonl",
        proposed=proposed,
        report=tmp_path / "r.md",
        dump_date=fixture_artifact.dump_date,
        root=fixture_artifact.root,
    )

    lines = [x for x in proposed.read_text(encoding="utf-8").split("\n") if x.strip()]
    assert len(lines) == 1
    row = EvalCase(**json.loads(lines[0]))
    assert row.label.labeled_by == "agent"
    assert row.label.verdict == "match"
    assert row.label.work_key == "OL8331643W"
    assert row.label.work_key in {c.work_key for c in row.candidates_shown}


def test_the_cli_proposes_nothing_when_corroboration_fails(tmp_path, fixture_artifact):
    """Same reachable work, but the candidate now names a different book by a
    different person. Replacing main()'s corroboration computation with a bare
    True left the suite green, so nothing checked that main consults it at
    all."""
    from openlibrary.eval.triage import main

    entry = _proposable()
    entry.candidates[0].title = "New Cookbook by Paul Anthony"
    entry.candidates[0].author_names = ["Paul Anthony"]
    proposed = tmp_path / "proposed.jsonl"

    main(
        pool=_pool_file(tmp_path, [entry]),
        labels=tmp_path / "labels.jsonl",
        proposed=proposed,
        report=tmp_path / "r.md",
        dump_date=fixture_artifact.dump_date,
        root=fixture_artifact.root,
    )

    assert proposed.read_text(encoding="utf-8").strip() == ""


def test_a_dropped_middle_initial_still_corroborates():
    """`name_subset` carries 10 of the 73 proposals -- `Irvin D. Yalom`
    against `irvin yalom`. Dropping it from the accepted set killed nothing."""
    from openlibrary.eval.triage import corroborated

    assert corroborated(_book(authors=["Irvin D. Yalom"]), _cand(authors=["Irvin Yalom"]))


def test_an_orphaned_identifier_is_counted_apart_from_an_absent_one(fixture_artifact):
    """Absent means Open Library has never heard of the number; orphaned means
    it holds it on an edition with no work key, which blocking cannot see.
    They route the same today but read differently in the dossier, and only
    `absent` was asserted -- zeroing the orphaned count killed nothing."""
    from openlibrary.eval.triage import fetch_identifier_reach
    from openlibrary.pipeline.duck import connect
    from openlibrary.pipeline.paths import ArtifactPaths

    paths = ArtifactPaths(root=fixture_artifact.root, dump_date=fixture_artifact.dump_date)
    con = connect(paths, memory_limit="2GB")
    row = con.execute(
        f"""SELECT value FROM '{paths.table("identifiers")}'
            WHERE work_key IS NULL AND id_type = 'isbn13' LIMIT 1"""
    ).fetchone()
    con.close()
    if row is None:
        pytest.skip("fixture corpus holds no work-less identifier")

    entry = _entry("orphan", "easy_baseline", [], isbn13=[row[0]])
    reach = fetch_identifier_reach(fixture_artifact.root, fixture_artifact.dump_date, [entry])

    assert reach["orphan"].works == frozenset()
    assert reach["orphan"].orphaned > 0
    assert reach["orphan"].absent == 0


def test_read_lines_splits_only_on_newline(tmp_path):
    """`str.splitlines()` also breaks on \\x85 and \\u2028, which truncated a
    JSON record in this very pool once. A record whose title contains one must
    survive as a single line."""
    from openlibrary.eval.triage import _read_lines

    p = tmp_path / "x.jsonl"
    p.write_text('{"a": "one two"}\n{"b": 2}\n', encoding="utf-8")

    assert len(_read_lines(p)) == 2


def test_the_dossier_lists_every_candidate_not_just_the_first_few(tmp_path, fixture_artifact):
    """The report clipped at 6 while 25% of cases carry more -- 21 of them the
    full 20. A researcher working from it kept reporting "only six of the
    stated 20 candidates were supplied", and its duplicate counts were
    minimums as a result. The dossier exists to be read; clipping it defeats
    the point."""
    from openlibrary.eval.build_pool import PoolCandidate
    from openlibrary.eval.triage import main

    entry = _entry("many", "shared_key_collision", [], isbn13=["9789999999999"])
    entry.candidates = [
        PoolCandidate(work_key=f"OL{i}W", rules=["title_fp"], title=f"Book {i}") for i in range(9)
    ]
    report = tmp_path / "r.md"

    main(
        pool=_pool_file(tmp_path, [entry]),
        labels=tmp_path / "labels.jsonl",
        proposed=tmp_path / "p.jsonl",
        report=report,
        dump_date=fixture_artifact.dump_date,
        root=fixture_artifact.root,
    )

    text = report.read_text(encoding="utf-8")
    for i in range(9):
        assert f"OL{i}W" in text, f"candidate OL{i}W missing from the dossier"
