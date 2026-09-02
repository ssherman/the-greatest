import datetime

import pytest

from openlibrary.eval.build_pool import PoolCandidate, PoolEntry
from openlibrary.eval.label import (
    already_labeled,
    append_case,
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
