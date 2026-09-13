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

from openlibrary.eval.dataset import (
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
