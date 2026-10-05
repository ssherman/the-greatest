from openlibrary.eval.compare import decision_diff, metric_rows, render_markdown


def _outcome(case_id, verdict, key, *, expected="OL1W", correct=False, stratum="list_row"):
    return {
        "case_id": case_id,
        "stratum": stratum,
        "expected_work_key": expected,
        "expected_verdict": "match",
        "decision": {
            "verdict": verdict,
            "work_key": key,
            "score": 0.9,
            "margin": 0.1,
            "reason": "r",
            "duplicates": [],
        },
        "candidate_rank": 1,
        "correct": correct,
        "false_merge": verdict == "accept" and not correct,
        "canonical": correct,
    }


def _reading(outcomes, abstention):
    return {
        "label": "x",
        "matcher_version": 2,
        "weights_calibrated_at": None,
        "metrics": {"abstention_rate": abstention, "false_merge_rate": 0.0},
        "by_stratum": {"list_row": {"abstention_rate": abstention, "false_merge_rate": 0.0}},
        "outcomes": outcomes,
    }


def test_decision_diff_lists_only_changed_cases_with_their_kind():
    before = _reading(
        [
            _outcome("a", "abstain", None),
            _outcome("b", "accept", "OL1W", correct=True),
            _outcome("c", "accept", "OL1W", correct=True),
            _outcome("d", "accept", "OL1W", correct=True),
        ],
        0.25,
    )
    after = _reading(
        [
            _outcome("a", "accept", "OL1W", correct=True),
            _outcome("b", "accept", "OL1W", correct=True),
            _outcome("c", "accept", "OL2W"),
            _outcome("d", "abstain", None),
        ],
        0.25,
    )
    rows = {r.case_id: r for r in decision_diff(before, after)}
    assert set(rows) == {"a", "c", "d"}
    assert rows["a"].change == "newly_accepted" and rows["a"].after_correct
    assert rows["c"].change == "key_changed" and not rows["c"].after_correct
    assert rows["d"].change == "newly_abstained"


def test_decision_diff_tolerates_decisions_without_a_duplicates_key():
    old = _outcome("a", "abstain", None)
    del old["decision"]["duplicates"]
    new = _outcome("a", "accept", "OL1W", correct=True)
    del new["decision"]["duplicates"]
    rows = decision_diff(_reading([old], 1.0), _reading([new], 0.0))
    assert [r.change for r in rows] == ["newly_accepted"]


def test_metric_rows_pairs_before_and_after_values():
    rows = metric_rows(_reading([], 0.9), _reading([], 0.3), stratum="list_row")
    assert ("abstention_rate", 0.9, 0.3) in rows


def test_markdown_names_both_readings_and_every_changed_case():
    before = _reading([_outcome("a", "abstain", None)], 1.0)
    after = _reading([_outcome("a", "accept", "OL1W", correct=True)], 0.0)
    text = render_markdown(before, after)
    assert "| abstention_rate |" in text
    assert "a" in text and "newly_accepted" in text
