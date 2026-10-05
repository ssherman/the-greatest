"""`eval.dataset`'s own tests: the loader, its proposal filter, and the
redirect-aware key comparison the matcher's evaluation harness will build on.

The redirect tests are pinned against known rows in the committed fixture
corpus (see tests/fixtures/test_fixture_corpus.py) rather than queried with
`LIMIT 1` + `pytest.skip`: a test that can skip silently stops testing the
thing it names.
"""

from __future__ import annotations

import contextlib
import datetime
import os

import pytest

from common.normalize import name_fingerprint
from openlibrary.eval.dataset import (
    WorkFacts,
    alternate_problems,
    check_alternates,
    fetch_work_facts,
    load_cases,
    resolve_keys,
    same_work,
    stratum_counts,
    unknown_labeled_keys,
    verdict_counts,
)
from openlibrary.eval.schema import (
    MIN_CASES,
    MIN_NO_MATCH_CASES,
    STRATA,
    EvalBook,
    EvalCase,
    EvalLabel,
)
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths

# Pinned to shapes the committed fixture corpus is known to hold (see
# tests/fixtures/test_fixture_corpus.py):
#   OL15331408W -> OL3809593W   the one resolvable work redirect
#   OL999999001W <-> OL999999002W   a synthetic cycle pair
#   OL26204513W -> OL16808392W   a dangling redirect (terminal absent from works)
RESOLVABLE_SOURCE = "OL15331408W"
RESOLVABLE_TERMINAL = "OL3809593W"
CYCLE_MEMBER = "OL999999001W"
DANGLING_SOURCE = "OL26204513W"
DANGLING_TERMINAL = "OL16808392W"


def _case(case_id: str, stratum: str, **label_overrides) -> EvalCase:
    label = dict(
        verdict="no_match",
        work_key=None,
        identity_rule="not_in_open_library",
        rationale="Checked Open Library by hand; there is no corresponding work.",
        labeled_at=datetime.date(2026, 9, 2),
        labeled_against_dump_date="2026-07-31",
    )
    label.update(label_overrides)
    return EvalCase(
        case_id=case_id,
        stratum=stratum,
        book=EvalBook(book_id=1, title="A Title"),
        candidates_shown=[],
        label=EvalLabel(**label),
    )


def test_load_reads_every_jsonl_file_in_the_directory(tmp_path):
    (tmp_path / "a.jsonl").write_text(_case("a-1", "easy_baseline").model_dump_json() + "\n")
    (tmp_path / "b.jsonl").write_text(_case("b-1", "easy_baseline").model_dump_json() + "\n")
    assert {c.case_id for c in load_cases(tmp_path)} == {"a-1", "b-1"}


def test_agent_researched_labels_are_ground_truth(tmp_path):
    case = _case("r-1", "list_row", labeled_by="agent_researched")
    (tmp_path / "list_rows.jsonl").write_text(case.model_dump_json() + "\n")
    assert [c.case_id for c in load_cases(tmp_path)] == ["r-1"]


def test_duplicate_case_ids_raise(tmp_path):
    (tmp_path / "a.jsonl").write_text(
        _case("dupe", "easy_baseline").model_dump_json()
        + "\n"
        + _case("dupe", "easy_baseline").model_dump_json()
        + "\n"
    )
    with pytest.raises(ValueError, match="duplicate"):
        load_cases(tmp_path)


def test_counts_helpers(tmp_path):
    (tmp_path / "a.jsonl").write_text(
        _case("a-1", "easy_baseline").model_dump_json()
        + "\n"
        + _case("a-2", "isbn_reuse").model_dump_json()
        + "\n"
    )
    cases = load_cases(tmp_path)
    assert stratum_counts(cases) == {"easy_baseline": 1, "isbn_reuse": 1}
    assert verdict_counts(cases) == {"no_match": 2}


def test_a_plain_agent_proposal_is_excluded_by_default(tmp_path):
    """A plain `agent` label is a proposal awaiting confirmation, not ground
    truth. `agent_confirmed` -- an agent's proposal a human or a further
    verification step has confirmed -- counts, same as a human label."""
    (tmp_path / "a.jsonl").write_text(
        _case("human-1", "easy_baseline").model_dump_json()
        + "\n"
        + _case("confirmed-1", "easy_baseline", labeled_by="agent_confirmed").model_dump_json()
        + "\n"
        + _case("proposed-1", "easy_baseline", labeled_by="agent").model_dump_json()
        + "\n"
    )
    assert {c.case_id for c in load_cases(tmp_path)} == {"human-1", "confirmed-1"}
    assert {c.case_id for c in load_cases(tmp_path, include_proposed=True)} == {
        "human-1",
        "confirmed-1",
        "proposed-1",
    }


def test_duplicate_case_ids_raise_even_when_one_copy_is_an_excluded_proposal(tmp_path):
    """The excluded-by-default `agent` row must still be seen by the
    duplicate check -- a proposal that quietly reuses a real case_id is a bug
    the set must not hide just because the proposal itself is filtered out."""
    (tmp_path / "a.jsonl").write_text(
        _case("dupe", "easy_baseline").model_dump_json()
        + "\n"
        + _case("dupe", "easy_baseline", labeled_by="agent").model_dump_json()
        + "\n"
    )
    with pytest.raises(ValueError, match="duplicate"):
        load_cases(tmp_path)


def test_a_key_that_is_not_redirected_resolves_to_itself(fixture_artifact):
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        (key,) = con.execute(
            f"SELECT work_key FROM '{fixture_artifact.table('works')}' LIMIT 1"
        ).fetchone()
        assert resolve_keys(con, fixture_artifact, [key])[key] == key


def test_a_redirected_key_resolves_to_its_terminal(fixture_artifact):
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        row = con.execute(
            f"""
            SELECT source_key, terminal_key FROM '{fixture_artifact.table("redirects")}'
            WHERE source_key = '{RESOLVABLE_SOURCE}'
            """
        ).fetchone()
        assert row == (RESOLVABLE_SOURCE, RESOLVABLE_TERMINAL)
        assert (
            resolve_keys(con, fixture_artifact, [RESOLVABLE_SOURCE])[RESOLVABLE_SOURCE]
            == RESOLVABLE_TERMINAL
        )


def test_a_cycle_members_key_resolves_to_itself(fixture_artifact):
    """A cycle member's `terminal_key` is NULL and `NOT r.is_cycle` excludes
    its redirect row from the join entirely, so `COALESCE` falls back to the
    key itself -- the conservative answer when OL's own data cannot say what
    the work became."""
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        assert resolve_keys(con, fixture_artifact, [CYCLE_MEMBER])[CYCLE_MEMBER] == CYCLE_MEMBER


def test_a_dangling_redirects_source_resolves_to_its_absent_terminal(fixture_artifact):
    """Resolution and existence are different questions: the source resolves
    to its terminal even though that terminal is not itself in `works`.
    `unknown_labeled_keys` is what catches the second question."""
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        assert (
            resolve_keys(con, fixture_artifact, [DANGLING_SOURCE])[DANGLING_SOURCE]
            == DANGLING_TERMINAL
        )


def test_same_work_compares_after_resolving_both_sides(fixture_artifact):
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        # A label written against last month's dump and a matcher answering
        # against this month's must still agree.
        assert same_work(con, fixture_artifact, RESOLVABLE_SOURCE, RESOLVABLE_TERMINAL)
        assert not same_work(con, fixture_artifact, RESOLVABLE_SOURCE, None)
        assert not same_work(con, fixture_artifact, None, None)


def test_unknown_labeled_keys_catches_a_typo(fixture_artifact, tmp_path):
    directory = tmp_path / "cases"
    directory.mkdir()
    (directory / "a.jsonl").write_text(
        _case(
            "a-1",
            "easy_baseline",
            verdict="match",
            work_key="OL999999999W",
            identity_rule="same_work",
        ).model_dump_json()
        + "\n"
    )
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        unknown = unknown_labeled_keys(con, fixture_artifact, load_cases(directory))
    assert ("a-1", "OL999999999W") in unknown


def test_unknown_labeled_keys_reports_a_dangling_redirects_source(fixture_artifact, tmp_path):
    """The label names the source key, as a real label written before OL
    deleted the target would. Resolution follows it to OL16808392W, which
    does not exist in `works` -- `unknown_labeled_keys` must catch that, not
    wave it through because the source itself once resolved to something."""
    directory = tmp_path / "cases"
    directory.mkdir()
    (directory / "a.jsonl").write_text(
        _case(
            "a-1",
            "easy_baseline",
            verdict="match",
            work_key=DANGLING_SOURCE,
            identity_rule="same_work",
        ).model_dump_json()
        + "\n"
    )
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        unknown = unknown_labeled_keys(con, fixture_artifact, load_cases(directory))
    assert ("a-1", DANGLING_SOURCE) in unknown


def test_the_committed_set_meets_its_quotas_and_has_enough_negatives():
    # Reads only the committed JSONL, so it runs everywhere -- a malformed or
    # duplicate row, or a quota regression, must fail plain `uv run pytest`.
    cases = load_cases()
    assert len(cases) >= MIN_CASES
    assert verdict_counts(cases).get("no_match", 0) >= MIN_NO_MATCH_CASES
    counts = stratum_counts(cases)
    short = {s: (counts.get(s, 0), q) for s, q in STRATA.items() if counts.get(s, 0) < q}
    # A short stratum is allowed -- the catalog may not contain enough of that
    # shape -- but it must be a conscious, recorded fact, so print it loudly.
    if short:
        print(f"strata below quota: {short}")
    assert sum(counts.values()) >= MIN_CASES


@pytest.mark.artifact
def test_every_labeled_key_exists_in_the_real_artifact():
    root = os.environ.get("OL_DATA_ROOT")
    dump_date = os.environ.get("OL_DATA_VERSION")
    if not (root and dump_date):
        pytest.skip("set OL_DATA_ROOT and OL_DATA_VERSION")
    from pathlib import Path

    paths = ArtifactPaths(root=Path(root), dump_date=dump_date)
    con = connect(paths, memory_limit="4GB")
    with contextlib.closing(con):
        unknown = unknown_labeled_keys(con, paths, load_cases())
    assert unknown == [], f"labeled work keys that do not exist: {unknown}"


@pytest.mark.artifact
def test_every_alternate_is_a_verified_duplicate_in_the_real_artifact():
    root = os.environ.get("OL_DATA_ROOT")
    dump_date = os.environ.get("OL_DATA_VERSION")
    if not (root and dump_date):
        pytest.skip("set OL_DATA_ROOT and OL_DATA_VERSION")
    from pathlib import Path

    paths = ArtifactPaths(root=Path(root), dump_date=dump_date)
    con = connect(paths, memory_limit="4GB")
    with contextlib.closing(con):
        problems = check_alternates(con, paths, load_cases())
    assert problems == [], f"alternates that are not verified duplicates: {problems}"


TITLE_PROBLEM = "shares no title with the labelled work or the case title"
AUTHOR_PROBLEM = "shares no author with the labelled work"


def _facts(key, title_fp="dune", noart="dune", authors=("frank herbert",), editions=1, title=None):
    return WorkFacts(
        work_key=key,
        title=title or key,
        title_fp=title_fp,
        title_fp_noart=noart,
        author_names=list(authors),
        author_fps=list(authors),
        edition_count=editions,
    )


def test_a_true_duplicate_has_no_problems():
    facts = {"OL1W": _facts("OL1W"), "OL2W": _facts("OL2W")}
    assert alternate_problems("OL1W", "OL2W", facts, resolved={}) == []


def test_an_alternate_that_redirects_to_the_label_is_a_problem():
    facts = {"OL1W": _facts("OL1W"), "OL2W": _facts("OL2W")}
    problems = alternate_problems("OL1W", "OL2W", facts, resolved={"OL2W": "OL1W"})
    assert problems == ["redirects to the labelled work; not a duplicate"]


def test_an_alternate_missing_from_works_is_a_problem():
    assert alternate_problems("OL1W", "OL9W", {"OL1W": _facts("OL1W")}, resolved={}) == [
        "not in works"
    ]


def test_an_alternate_with_another_title_or_author_is_a_problem():
    facts = {
        "OL1W": _facts("OL1W"),
        "OL2W": _facts(
            "OL2W",
            title_fp="children of dune",
            noart="children of dune",
            authors=("brian herbert",),
        ),
    }
    assert sorted(alternate_problems("OL1W", "OL2W", facts, resolved={})) == sorted(
        [TITLE_PROBLEM, AUTHOR_PROBLEM]
    )


def test_matching_title_with_different_authors_is_only_an_author_problem():
    facts = {"OL1W": _facts("OL1W"), "OL2W": _facts("OL2W", authors=("brian herbert",))}
    assert alternate_problems("OL1W", "OL2W", facts, resolved={}) == [AUTHOR_PROBLEM]


def test_matching_author_with_different_title_is_only_a_title_problem():
    facts = {"OL1W": _facts("OL1W"), "OL2W": _facts("OL2W", title_fp="messiah", noart="messiah")}
    assert alternate_problems("OL1W", "OL2W", facts, resolved={}) == [TITLE_PROBLEM]


def test_an_article_stripped_title_match_is_enough():
    facts = {
        "OL1W": _facts("OL1W", title_fp="the dune", noart="dune"),
        "OL2W": _facts("OL2W", title_fp="dune", noart="dune"),
    }
    assert alternate_problems("OL1W", "OL2W", facts, resolved={}) == []


def test_a_shared_subtitle_stripped_title_is_not_a_duplicate_title():
    facts = {
        "OL1W": _facts("OL1W", title_fp="harry potter series 1 7", noart="harry potter series 1 7"),
        "OL2W": _facts("OL2W", title_fp="harry potter series 1 4", noart="harry potter series 1 4"),
    }
    assert alternate_problems("OL1W", "OL2W", facts, resolved={}) == [TITLE_PROBLEM]


def _mislabelled_label_facts(alt_authors=("frank herbert",)):
    return {
        "OL1W": _facts("OL1W", title_fp="el buen nombre lingua franca", noart="buen nombre"),
        "OL2W": _facts("OL2W", title_fp="the namesake", noart="namesake", authors=alt_authors),
    }


def test_an_alternate_equal_to_the_case_title_is_a_duplicate():
    problems = alternate_problems(
        "OL1W", "OL2W", _mislabelled_label_facts(), {}, case_title="The Namesake"
    )
    assert problems == []


def test_the_same_alternate_without_a_case_title_has_a_title_problem():
    assert alternate_problems("OL1W", "OL2W", _mislabelled_label_facts(), {}) == [TITLE_PROBLEM]


def test_a_case_title_match_still_needs_a_shared_author():
    facts = _mislabelled_label_facts(alt_authors=("jhumpa lahiri",))
    problems = alternate_problems("OL1W", "OL2W", facts, {}, case_title="The Namesake")
    assert problems == [AUTHOR_PROBLEM]


def test_a_short_shared_fingerprint_with_different_raw_titles_is_not_a_match():
    facts = {
        "OL1W": _facts("OL1W", title_fp="6", noart="6", title="エマ 6"),
        "OL2W": _facts("OL2W", title_fp="6", noart="6", title="シャーリー 6"),
    }
    assert alternate_problems("OL1W", "OL2W", facts, {}) == [TITLE_PROBLEM]


def test_a_short_shared_fingerprint_with_equal_raw_titles_is_a_match():
    facts = {
        "OL1W": _facts("OL1W", title_fp="q a", noart="q a", title="Q & A"),
        "OL2W": _facts("OL2W", title_fp="q a", noart="q a", title="Q  &  A"),
    }
    assert alternate_problems("OL1W", "OL2W", facts, {}) == []


def test_a_short_fingerprint_with_raw_titles_that_differ_is_not_a_match():
    facts = {
        "OL1W": _facts("OL1W", title_fp="q a", noart="q a", title="Q & A"),
        "OL2W": _facts("OL2W", title_fp="q a", noart="q a", title="Q / A"),
    }
    assert alternate_problems("OL1W", "OL2W", facts, {}) == [TITLE_PROBLEM]


def test_a_short_case_title_needs_an_equal_raw_alternate_title():
    facts = {
        "OL1W": _facts("OL1W", title_fp="other", noart="other"),
        "OL2W": _facts("OL2W", title_fp="s", noart="s", title="S."),
    }
    assert alternate_problems("OL1W", "OL2W", facts, {}, case_title="S.") == []
    facts["OL2W"] = _facts("OL2W", title_fp="s", noart="s", title="S!")
    assert alternate_problems("OL1W", "OL2W", facts, {}, case_title="S.") == [TITLE_PROBLEM]


def test_an_empty_title_fingerprint_never_matches():
    facts = {
        "OL1W": _facts("OL1W", title_fp="", noart=""),
        "OL2W": _facts("OL2W", title_fp="", noart=""),
    }
    assert alternate_problems("OL1W", "OL2W", facts, resolved={}) == [TITLE_PROBLEM]


def test_an_alternate_with_no_authors_is_an_author_problem():
    facts = {"OL1W": _facts("OL1W"), "OL2W": _facts("OL2W", authors=())}
    assert alternate_problems("OL1W", "OL2W", facts, resolved={}) == [AUTHOR_PROBLEM]


def test_a_label_that_redirects_to_the_alternate_is_a_problem():
    facts = {"OL1W": _facts("OL1W"), "OL2W": _facts("OL2W")}
    problems = alternate_problems("OL1W", "OL2W", facts, resolved={"OL1W": "OL2W"})
    assert problems == ["redirects to the labelled work; not a duplicate"]


def test_an_alternate_equal_to_the_label_key_says_so():
    facts = {"OL1W": _facts("OL1W")}
    assert alternate_problems("OL1W", "OL1W", facts, resolved={}) == [
        "alternate is the labelled key"
    ]


def test_fetch_work_facts_reads_titles_and_authors(fixture_artifact, fixture_labelled_works):
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        (key, title, authors), (key2, title2, authors2) = fixture_labelled_works[:2]
        facts = fetch_work_facts(con, fixture_artifact, [key, key2])
    assert set(facts) == {key, key2}
    for k, t, names in ((key, title, authors), (key2, title2, authors2)):
        assert facts[k].title == t
        assert facts[k].title_fp
        assert set(facts[k].author_names) == set(names)
        assert facts[k].author_fps == sorted({name_fingerprint(n) for n in names})


def _match_case(work_key, alternates):
    return EvalCase(
        case_id="alt-001",
        stratum="easy_baseline",
        book=EvalBook(book_id=1, title="Whatever"),
        candidates_shown=[],
        label=EvalLabel(
            verdict="match",
            work_key=work_key,
            alternate_work_keys=alternates,
            identity_rule="same_work",
            rationale="Constructed from the artifact for the alternate test.",
            labeled_at=datetime.date(2026, 10, 4),
            labeled_against_dump_date="2026-07-31",
        ),
    )


def test_check_alternates_reports_each_problem_per_alternate(
    fixture_artifact, fixture_labelled_works
):
    label_key = fixture_labelled_works[0][0]
    unrelated = fixture_labelled_works[1][0]
    case = _match_case(label_key, [unrelated, "OL999999999W"])
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        problems = check_alternates(con, fixture_artifact, [case])
    assert sorted(problems) == sorted(
        [
            ("alt-001", unrelated, TITLE_PROBLEM),
            ("alt-001", unrelated, AUTHOR_PROBLEM),
            ("alt-001", "OL999999999W", "not in works"),
        ]
    )


# Synthetic fixture works with the same title_fp ("selected poems") and a shared
# author fingerprint ("amelia atwater rhodes"): a true duplicate pair.
DUPLICATE_LABEL, DUPLICATE_ALTERNATE = "OL999999101W", "OL999999151W"


def test_check_alternates_accepts_a_true_duplicate(fixture_artifact):
    case = _match_case(DUPLICATE_LABEL, [DUPLICATE_ALTERNATE])
    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        assert check_alternates(con, fixture_artifact, [case]) == []
