from common.gates import GateResult, within_tolerance


def test_a_first_build_with_no_previous_is_always_within_tolerance():
    assert within_tolerance(None, 41_504_065, max_drop=0.05, max_rise=0.50)


def test_a_small_change_passes():
    assert within_tolerance(41_000_000, 41_504_065, max_drop=0.05, max_rise=0.50)


def test_a_truncated_dump_fails():
    # The failure this gate exists for: a half-downloaded dump that parses fine.
    assert not within_tolerance(41_504_065, 20_000_000, max_drop=0.05, max_rise=0.50)


def test_an_implausible_explosion_fails():
    assert not within_tolerance(41_504_065, 200_000_000, max_drop=0.05, max_rise=0.50)


def test_gate_result_carries_its_observation():
    result = GateResult(name="row_count", status="fail", detail="dropped 51%", observed={"n": 1})
    assert result.status == "fail"
    assert result.observed["n"] == 1
