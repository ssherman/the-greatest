import datetime

import pytest

from openlibrary.eval.build_pool import PoolCandidate, PoolEntry
from openlibrary.eval.label import (
    already_labeled,
    append_case,
    candidates_shown_for,
    default_rationale,
    parse_choice,
    render_case,
)
from openlibrary.eval.schema import EvalBook, EvalCase, EvalLabel


@pytest.fixture()
def entry() -> PoolEntry:
    return PoolEntry(
        case_id="shared_key_collision-001",
        stratum="shared_key_collision",
        book=EvalBook(
            book_id=48213,
            title="The Golden Apple",
            author_names=["Robert Shea", "Robert Anton Wilson"],
            first_published_year=1975,
            isbn13=["9780440313427"],
            existing_ol_work_keys=["OL15331408W"],
        ),
        candidates=[
            PoolCandidate(
                work_key="OL15331408W",
                rules=["existing_key"],
                title="The Illuminatus! Trilogy",
                author_names=["Robert Shea"],
                declared_year=1975,
                edition_count=23,
                readinglog_count=1204,
                title_fp_freq=1,
            ),
            PoolCandidate(
                work_key="OL8384219W",
                rules=["author_title_fp"],
                title="The Golden Apple",
                author_names=["Robert Shea", "Robert Anton Wilson"],
                declared_year=1975,
                edition_count=4,
                readinglog_count=61,
                title_fp_freq=7,
            ),
        ],
    )


def test_render_shows_our_book_and_every_candidate(entry):
    text = render_case(entry, index=1, total=450)
    assert "The Golden Apple" in text
    assert "Robert Anton Wilson" in text
    assert "OL15331408W" in text
    assert "OL8384219W" in text


def test_render_shows_the_rules_that_produced_each_candidate(entry):
    text = render_case(entry, index=1, total=450)
    assert "existing_key" in text
    assert "author_title_fp" in text


def test_render_includes_an_open_library_url_for_each_candidate(entry):
    text = render_case(entry, index=1, total=450)
    assert "https://openlibrary.org/works/OL8384219W" in text


def test_render_uses_no_ansi_colour_at_all(entry):
    # Meaning must never be carried by hue: this tool is used by a red-green
    # colour-blind reader, and a colour-only distinction carries no information.
    text = render_case(entry, index=1, total=450)
    assert "\x1b[" not in text


def test_render_shows_progress(entry):
    assert "1/450" in render_case(entry, index=1, total=450)


def test_choose_recap_lists_every_candidate_and_names_the_real_upper_bound(entry):
    # A 20-candidate case is the worst real one in the pool (King John,
    # shared_key_collision-002): the detail block scrolls candidate [1] off
    # screen long before the prompt, so the final screen must repeat every
    # candidate's number where the labeler is actually choosing.
    many = entry.model_copy(
        update={
            "candidates": [
                PoolCandidate(
                    work_key=f"OL{1000000 + n}W",
                    rules=["title_fp"],
                    title=f"Candidate {n}",
                    author_names=["Some Author"],
                    edition_count=n,
                    readinglog_count=n * 10,
                )
                for n in range(1, 21)
            ]
        }
    )
    text = render_case(many, index=1, total=450)
    for position in range(1, 21):
        assert f" [{position:>2}] " in text, f"candidate {position} missing from the recap"
    assert "[1-20] pick a candidate" in text
    assert "[1-9]" not in text


def test_zero_candidate_entry_renders_without_a_pick_range(entry):
    # 96 of the 450 real cases have no candidates at all.
    none = entry.model_copy(update={"candidates": []})
    text = render_case(none, index=1, total=450)
    assert "(no candidates to pick)" in text
    assert "pick a candidate" not in text


def test_choosing_a_number_picks_that_candidate(entry):
    choice = parse_choice("2", entry)
    assert choice.kind == "candidate"
    assert choice.work_key == "OL8384219W"


def test_choosing_out_of_range_is_rejected(entry):
    assert parse_choice("9", entry).kind == "invalid"


def test_n_records_no_match(entry):
    assert parse_choice("n", entry).kind == "no_match"


def test_a_records_ambiguous(entry):
    assert parse_choice("a", entry).kind == "ambiguous"


def test_k_followed_by_a_key_records_a_manual_key(entry):
    choice = parse_choice("k OL1234567W", entry)
    assert choice.kind == "manual_key"
    assert choice.work_key == "OL1234567W"


def test_a_manual_key_must_look_like_a_work_key(entry):
    assert parse_choice("k not-a-key", entry).kind == "invalid"


def test_s_skips_and_q_quits(entry):
    assert parse_choice("s", entry).kind == "skip"
    assert parse_choice("q", entry).kind == "quit"


def test_candidates_shown_uses_the_complete_generated_set_not_the_display_cap(entry):
    # `entry.candidates` is capped at 20 for the terminal display; `all_generated`
    # carries the complete set blocking produced. A labeler who manually enters a
    # key that blocking DID produce -- just not inside the top 20 shown -- must
    # NOT have that recorded as `found_outside_blocking`, which is reserved for
    # keys no rule produced at all. If `candidates_shown` were built from the
    # capped `entry.candidates` instead, this key would wrongly look unseen.
    beyond_the_cap = PoolCandidate(
        work_key="OL9999999W",
        rules=["title_fp"],
        title="Ranked 21st, Never Displayed",
    )
    entry_with_full_set = entry.model_copy(
        update={"all_generated": entry.candidates + [beyond_the_cap]}
    )
    assert beyond_the_cap.work_key not in {c.work_key for c in entry_with_full_set.candidates}

    case = EvalCase(
        case_id=entry.case_id,
        stratum=entry.stratum,
        book=entry.book,
        candidates_shown=candidates_shown_for(entry_with_full_set),
        label=EvalLabel(
            verdict="match",
            work_key="OL9999999W",
            identity_rule="same_work",
            rationale="Confirmed by hand on openlibrary.org; blocking ranked it 21st+.",
            labeled_at=datetime.date(2026, 9, 2),
            labeled_against_dump_date="2026-07-31",
        ),
    )
    assert case.found_outside_blocking is False


def test_resume_skips_case_ids_already_written(tmp_path, entry):
    out = tmp_path / "labels.jsonl"
    case = EvalCase(
        case_id=entry.case_id,
        stratum=entry.stratum,
        book=entry.book,
        candidates_shown=[],
        label=EvalLabel(
            verdict="no_match",
            work_key=None,
            identity_rule="not_in_open_library",
            rationale="Checked openlibrary.org by hand; nothing matches.",
            labeled_at=datetime.date(2026, 9, 2),
            labeled_against_dump_date="2026-07-31",
        ),
    )
    append_case(out, case)

    assert already_labeled(out) == {entry.case_id}


def test_append_is_additive_not_a_rewrite(tmp_path, entry):
    out = tmp_path / "labels.jsonl"
    for case_id in ("a-001", "a-002"):
        append_case(
            out,
            EvalCase(
                case_id=case_id,
                stratum="easy_baseline",
                book=entry.book,
                candidates_shown=[],
                label=EvalLabel(
                    verdict="no_match",
                    work_key=None,
                    identity_rule="not_in_open_library",
                    rationale="Nothing in Open Library corresponds to this book.",
                    labeled_at=datetime.date(2026, 9, 2),
                    labeled_against_dump_date="2026-07-31",
                ),
            ),
        )
    assert already_labeled(out) == {"a-001", "a-002"}


# --- default rationales -------------------------------------------------
#
# Typing a >= 10 character sentence 450 times is over an hour of keystrokes,
# and on an easy case the reasoning is derivable from the case itself: the
# labeller has nothing to add beyond "the evidence agreed". So the CLI offers
# a factual default that Enter accepts. The schema still requires a rationale
# on every label -- what changes is who types it, not whether it exists.
#
# It stays empty, and therefore mandatory, exactly where the reasoning is NOT
# derivable: an `ambiguous` verdict is a judgement call by definition, and a
# hand-entered key is the most valuable case in the set.


def test_a_match_defaults_to_the_evidence_that_agreed(entry):
    from openlibrary.eval.label import default_rationale

    text = default_rationale(entry, verdict="match", work_key="OL15331408W")

    assert "existing_key" in text
    assert len(text) >= 10


def test_a_no_match_defaults_to_what_was_rejected(entry):
    from openlibrary.eval.label import default_rationale

    text = default_rationale(entry, verdict="no_match", work_key=None)

    assert str(len(entry.candidates)) in text
    assert len(text) >= 10


def test_an_ambiguous_verdict_has_no_default(entry):
    """Ambiguity is the labeller's judgement; a machine-written default would
    be a fabricated one."""
    from openlibrary.eval.label import default_rationale

    assert default_rationale(entry, verdict="ambiguous", work_key=None) == ""


def test_a_key_no_rule_produced_has_no_default(entry):
    """`found_outside_blocking` cases are the only evidence of a recall
    failure the set will ever contain. They get typed."""
    from openlibrary.eval.label import default_rationale

    assert default_rationale(entry, verdict="match", work_key="OL_NOT_A_CANDIDATE_W") == ""


@pytest.fixture()
def entry_without_candidates() -> PoolEntry:
    """A real `no_candidates` case: a German Merian travel guide whose ISBN is
    absent from Open Library, whose stored `author` is the publisher, and whose
    title fingerprint (`thailand`, 594 OL works) is over MAX_TITLE_FP_FREQ. All
    four blocking rules correctly produced nothing."""
    return PoolEntry(
        case_id="no_candidates-001",
        stratum="no_candidates",
        book=EvalBook(
            book_id=93053,
            title="Merian Thailand",
            author_names=["Jahreszeitenverlag"],
            isbn13=["9783834227355"],
        ),
        candidates=[],
    )


def test_a_no_match_with_no_candidates_records_the_search_not_the_empty_list(
    entry_without_candidates,
):
    """`no_candidates` is 50 of the 450 cases and most will be no_match, so this
    default gets accepted more than any other. "none of the 0 candidates shown"
    is both silly and a lie about where the evidence came from: nothing was
    rejected, because nothing was offered. The verdict rests on the labeller
    searching Open Library directly, and that is what the rationale must say."""
    text = default_rationale(entry_without_candidates, verdict="no_match", work_key=None)

    assert "0 candidates" not in text
    assert "open library" in text.lower()
    assert len(text) >= 10


# A `no_candidates` verdict rests on a hand search of Open Library, and every
# other stratum needs one whenever the candidates look wrong. The details above
# are laid out to be read, which makes them awkward to copy: the title is
# quoted, the authors sit behind a label, and both are indented. One flush-left
# line with nothing but the query saves a retype 450 times over.


def test_a_flush_left_search_line_pairs_the_title_with_the_authors(entry):
    line = "The Golden Apple by Robert Shea, Robert Anton Wilson"

    assert line in render_case(entry, index=1, total=450).splitlines()


def test_the_search_line_carries_no_quotes_or_indent(entry):
    """Triple-clicking selects a whole line, so anything sharing the line ends
    up in the search box. The repr quotes on the OURS line are the reason this
    line exists."""
    text = render_case(entry, index=1, total=450)

    line = next(ln for ln in text.splitlines() if ln.startswith("The Golden Apple by"))
    assert line == line.strip()
    assert "'" not in line


def test_a_book_with_no_author_gets_a_search_line_without_a_dangling_by():
    entry = PoolEntry(
        case_id="no_candidates-002",
        stratum="no_candidates",
        book=EvalBook(book_id=1, title="Kebra Nagast", author_names=[]),
        candidates=[],
    )

    assert "Kebra Nagast" in render_case(entry, index=1, total=450).splitlines()


# The curation columns exist because the tiebreak between two OL works that are
# the same book turns on `revision` and identifier spread, and neither is in the
# pool. They are shown, never applied: which candidates ARE one book is the
# labeller's judgement, and a marker that guessed it pointed at Jack London on
# a 20-candidate `Fantastic Tales` case where 13 candidates were different books.


def _detail(**kw):
    from openlibrary.eval.label import CandidateDetail

    return CandidateDetail(**{"revision": 0, "last_modified": None, "id_types": 0, **kw})


def test_render_shows_revision_and_identifier_spread_for_each_candidate(entry):
    from openlibrary.eval.label import render_case

    text = render_case(
        entry,
        index=1,
        total=450,
        details={
            "OL15331408W": _detail(revision=8, id_types=6, last_modified="2025-10-29"),
            "OL8384219W": _detail(revision=1, id_types=2),
        },
    )

    assert "rev=8" in text
    assert "rev=1" in text
    assert "2025-10-29" in text


def test_render_without_details_still_works(entry):
    """The tool must run against a dump the artifact is not mounted for."""
    from openlibrary.eval.label import render_case

    assert "OL15331408W" in render_case(entry, index=1, total=450)


def test_curation_detail_is_read_from_the_artifact(fixture_artifact):
    """The pure ranking is pinned above; this pins the read that feeds it.

    Without it the SQL could return every revision as 0 and the tiebreak would
    silently fall through to reading-log -- which is the exact failure that
    made this data worth putting on screen in the first place.
    """
    from openlibrary.eval.label import fetch_candidate_details

    details = fetch_candidate_details(
        fixture_artifact.root, fixture_artifact.dump_date, ["OL81205W", "OL100077W"]
    )

    assert details["OL81205W"].revision == 17
    assert details["OL100077W"].revision == 7
    assert details["OL100077W"].last_modified == "2022-10-05"


def test_a_missing_artifact_disables_the_column_rather_than_failing(tmp_path):
    """`--root` pointing nowhere must still let someone label."""
    from openlibrary.eval.label import fetch_candidate_details

    assert fetch_candidate_details(tmp_path / "nope", "2026-07-31", ["OL1W"]) is None


def test_the_curation_columns_carry_a_warning_about_title_only_matches(entry):
    """A 20-candidate list is usually one book plus nineteen that share a
    generic title. Nothing on the CHOOSE line distinguishes them, so the legend
    has to send the reader back to title_fp_freq."""
    text = render_case(entry, index=1, total=450, details={})
    legend = text.split("CHOOSE")[1]

    assert "keep only the candidates 'our ids' reaches" in legend
    # `title_fp_freq` also appears in the per-candidate detail block above, so
    # this has to look at the legend specifically or it passes either way.
    assert "check title_fp_freq" in legend


def test_nothing_in_the_render_marks_a_preferred_candidate(entry):
    """The tool must not point at an answer. Ranking across all candidates
    ranks across different books."""
    text = render_case(
        entry,
        index=1,
        total=450,
        details={"OL15331408W": _detail(revision=99), "OL8384219W": _detail(revision=1)},
    )

    assert not any(line.startswith(">") for line in text.splitlines())


# Which of OUR identifiers reach a candidate is the single most decisive signal
# in this stratum, and the pool only records that SOME identifier rule fired --
# not which id, nor how many. On `What to Expect When You're Expecting` that
# distinction cut 17 candidates to one: all three of our ISBNs and our Goodreads
# id land on OL521324W and nothing of ours touches the runner-up.


def test_each_candidate_shows_which_of_our_identifiers_reach_it(entry):
    text = render_case(
        entry,
        index=1,
        total=450,
        id_hits={"OL15331408W": ["goodreads", "isbn10", "isbn13"], "OL8384219W": []},
    )

    assert "our ids: goodreads, isbn10, isbn13" in text


def test_a_candidate_no_identifier_of_ours_reaches_says_so(entry):
    """Silence would read as "not looked up". These are the candidates that
    matched on title or author alone."""
    text = render_case(
        entry, index=1, total=450, id_hits={"OL15331408W": ["isbn13"], "OL8384219W": []}
    )

    assert "our ids: none" in text


def test_without_the_lookup_no_identifier_line_is_shown(entry):
    assert "our ids:" not in render_case(entry, index=1, total=450)


def _entry_with(case_id, candidates, **ids):
    from openlibrary.eval.build_pool import PoolCandidate

    return PoolEntry(
        case_id=case_id,
        stratum="isbn_reuse",
        book=EvalBook(book_id=1, title="x", author_names=["y"], **ids),
        candidates=[PoolCandidate(work_key=k, rules=["identifier"]) for k in candidates],
    )


def test_an_identifier_hit_is_attributed_only_to_the_work_that_carries_it(fixture_artifact):
    """Without the work_key join every candidate in the case would show the
    hit, which is the one thing this line exists to distinguish."""
    from openlibrary.eval.label import fetch_identifier_hits

    entry = _entry_with("isbn_reuse-a", ["OL108593W", "OL100077W"], isbn10=["080782156X"])

    hits = fetch_identifier_hits(fixture_artifact.root, fixture_artifact.dump_date, [entry])

    # `_identifier_pairs` also derives the ISBN-13 form from an ISBN-10, so one
    # stored value legitimately reaches the work under both types.
    assert hits["isbn_reuse-a"] == {"OL108593W": ["isbn10", "isbn13"]}


def test_a_value_that_matches_under_a_different_id_type_is_not_a_hit(fixture_artifact):
    """`89036396` is an LCCN in the corpus. A book holding that number as a
    GOODREADS id has not matched anything -- and this is not hypothetical:
    our goodreads ids 135034, 1039053, 3811210 and 23403374 all collide with
    OCLC numbers on unrelated Open Library works.
    """
    from openlibrary.eval.label import fetch_identifier_hits

    entry = _entry_with("isbn_reuse-b", ["OL108593W"], goodreads_id=["89036396"])

    hits = fetch_identifier_hits(fixture_artifact.root, fixture_artifact.dump_date, [entry])

    assert hits["isbn_reuse-b"] == {}
