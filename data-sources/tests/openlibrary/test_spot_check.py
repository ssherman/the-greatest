import datetime

import pytest

from openlibrary.eval.dataset import WorkFacts
from openlibrary.eval.schema import EvalBook, EvalCase, EvalLabel
from openlibrary.eval.spot_check import render_sheet, sample_cases


@pytest.fixture
def make_case():
    def build(case_id, *, stratum, work_key="OL1W", title="A Title", verdict="match"):
        return EvalCase(
            case_id=case_id,
            stratum=stratum,
            book=EvalBook(book_id=1, title=title, author_names=["Frank Herbert"]),
            label=EvalLabel(
                verdict=verdict,
                work_key=work_key if verdict == "match" else None,
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
    assert "Frank Herbert" in sheet and "160" in sheet


def test_sheet_renders_a_label_with_no_work_key(make_case):
    case = make_case("list_row-002", stratum="list_row", verdict="no_match")
    sheet = render_sheet([case], {})
    assert "list_row-002" in sheet and "no_match" in sheet
