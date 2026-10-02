import asyncio

import pytest

from fetcher.budget import Budget, StageTimeout


def test_remaining_counts_down_and_never_goes_negative():
    now = [100.0]
    budget = Budget(2.0, clock=lambda: now[0])
    assert budget.remaining() == 2.0
    now[0] = 101.5
    assert budget.remaining() == pytest.approx(0.5)
    now[0] = 105.0
    assert budget.remaining() == 0.0


@pytest.mark.anyio
async def test_run_returns_the_result_within_the_budget():
    async def work():
        return 42

    assert await Budget(1).run(work(), "working") == 42


@pytest.mark.anyio
async def test_run_raises_a_stage_timeout_naming_the_stage():
    with pytest.raises(StageTimeout) as caught:
        await Budget(0.05).run(asyncio.sleep(1), "loading the page")
    assert caught.value.stage == "loading the page"


@pytest.mark.anyio
async def test_a_spent_budget_times_out_without_running_the_work():
    ran = False

    async def work():
        nonlocal ran
        ran = True

    now = [0.0]
    budget = Budget(1, clock=lambda: now[0])
    now[0] = 5.0
    with pytest.raises(StageTimeout):
        await budget.run(work(), "launching the browser")
    assert ran is False
