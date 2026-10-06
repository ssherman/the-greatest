import datetime
import re

import pytest

from openlibrary.eval.dataset import WorkFacts
from openlibrary.eval.schema import EvalBook, EvalCase, EvalLabel
from openlibrary.eval.spot_check import render_sheet, sample_cases


@pytest.fixture
def make_case():
    def build(
        case_id, *, stratum, work_key="OL1W", title="A Title", verdict="match", alternates=()
    ):
        return EvalCase(
            case_id=case_id,
            stratum=stratum,
            book=EvalBook(book_id=1, title=title, author_names=["Frank Herbert"]),
            label=EvalLabel(
                verdict=verdict,
                work_key=work_key if verdict == "match" else None,
                alternate_work_keys=list(alternates),
                identity_rule="same_work" if verdict == "match" else "not_in_open_library",
                rationale="Matched by title and author.",
                labeled_at=datetime.date(2026, 10, 4),
                labeled_against_dump_date="2026-07-31",
                labeled_by="agent_researched",
            ),
        )

    return build


def test_sample_is_seeded_and_filtered(make_case):
    cases = [make_case(f"list_row-{i:03d}", stratum="list_row") for i in range(40)]
    cases += [make_case("easy_baseline-001", stratum="easy_baseline")]
    first = sample_cases(cases, stratum="list_row", with_alternates=False, n=30, seed=1)
    again = sample_cases(cases, stratum="list_row", with_alternates=False, n=30, seed=1)
    assert first == again
    assert len(first) == 30 and all(c.stratum == "list_row" for c in first)


def test_sheet_links_each_labelled_work_and_shows_its_title(make_case):
    case = make_case("list_row-001", stratum="list_row", work_key="OL1W", title="Dune")
    facts = {
        "OL1W": WorkFacts(
            work_key="OL1W", title="Dune", author_names=["Frank Herbert"], edition_count=160
        )
    }
    sheet = render_sheet([case], facts)
    assert "https://openlibrary.org/works/OL1W" in sheet
    assert "Dune / Frank Herbert (160 editions)" in sheet


def test_sheet_renders_a_label_with_no_work_key(make_case):
    case = make_case("list_row-002", stratum="list_row", verdict="no_match")
    sheet = render_sheet([case], {})
    assert "list_row-002" in sheet and "no_match" in sheet


def test_sheet_escapes_pipes_so_the_row_keeps_its_columns(make_case):
    case = make_case("non_latin_title-026", stratum="non_latin_title", title="A | B")
    sheet = render_sheet([case], {})
    row = next(line for line in sheet.splitlines() if line.startswith("| non_latin"))
    assert "A \\| B" in row
    assert len(re.findall(r"(?<!\\)\|", row)) == 7


def test_sheet_says_so_when_facts_are_missing_or_untitled(make_case):
    case = make_case("list_row-003", stratum="list_row", work_key="OL1W", alternates=["OL2W"])
    facts = {"OL2W": WorkFacts(work_key="OL2W", edition_count=3)}
    sheet = render_sheet([case], facts)
    assert "(not found in the artifact)" in sheet
    assert "(no title)" in sheet


def test_sheet_lists_every_alternate_with_its_link(make_case):
    case = make_case("list_row-004", stratum="list_row", alternates=["OL2W", "OL3W"])
    sheet = render_sheet([case], {})
    assert "https://openlibrary.org/works/OL2W" in sheet
    assert "https://openlibrary.org/works/OL3W" in sheet


def test_different_seeds_pick_different_cases(make_case):
    cases = [make_case(f"list_row-{i:03d}", stratum="list_row") for i in range(40)]
    one = sample_cases(cases, stratum=None, with_alternates=False, n=10, seed=1)
    two = sample_cases(cases, stratum=None, with_alternates=False, n=10, seed=2)
    assert one != two


def test_with_alternates_samples_only_cases_that_have_them(make_case):
    plain = [make_case(f"list_row-{i:03d}", stratum="list_row") for i in range(10)]
    dupes = [
        make_case(f"easy_baseline-{i:03d}", stratum="easy_baseline", alternates=["OL2W"])
        for i in range(5)
    ]
    got = sample_cases(plain + dupes, stratum=None, with_alternates=True, n=30, seed=1)
    assert {c.case_id for c in got} == {c.case_id for c in dupes}


def test_exclude_stratum_drops_that_stratum(make_case):
    cases = [
        make_case("list_row-001", stratum="list_row", alternates=["OL2W"]),
        make_case("easy_baseline-001", stratum="easy_baseline", alternates=["OL2W"]),
    ]
    got = sample_cases(
        cases, stratum=None, with_alternates=True, n=30, seed=1, exclude_stratum="list_row"
    )
    assert [c.case_id for c in got] == ["easy_baseline-001"]
