import asyncio
import time

import pytest

from fetcher.budget import Budget, StageTimeout
from fetcher.limiter import Limiter

pytestmark = pytest.mark.anyio


async def test_no_more_than_max_concurrency_slots_are_held_at_once():
    limiter = Limiter(max_concurrency=2, host_interval_s=0)
    holding = 0
    peak = 0

    async def fetch(host):
        nonlocal holding, peak
        async with limiter.slot(host, Budget(5)):
            holding += 1
            peak = max(peak, holding)
            await asyncio.sleep(0.05)
            holding -= 1

    await asyncio.gather(*(fetch(f"h{i}.example") for i in range(5)))
    assert peak == 2


async def test_starts_to_the_same_host_are_spaced_by_the_interval():
    limiter = Limiter(max_concurrency=2, host_interval_s=0.2)
    starts = []

    async def fetch():
        async with limiter.slot("a.example", Budget(5)):
            starts.append(time.monotonic())

    await asyncio.gather(fetch(), fetch(), fetch())
    gaps = [later - earlier for earlier, later in zip(starts, starts[1:], strict=False)]
    assert all(gap >= 0.19 for gap in gaps), gaps


async def test_different_hosts_are_not_spaced_from_each_other():
    limiter = Limiter(max_concurrency=2, host_interval_s=1.0)
    started = time.monotonic()
    async with limiter.slot("a.example", Budget(5)):
        pass
    async with limiter.slot("b.example", Budget(5)):
        pass
    assert time.monotonic() - started < 0.1


async def test_a_spacing_wait_longer_than_the_budget_times_out_at_once():
    limiter = Limiter(max_concurrency=2, host_interval_s=10.0)
    async with limiter.slot("a.example", Budget(5)):
        pass
    started = time.monotonic()
    with pytest.raises(StageTimeout) as caught:
        async with limiter.slot("a.example", Budget(0.5)):
            pass
    assert caught.value.stage == "waiting for host spacing"
    assert time.monotonic() - started < 0.1  # did not sleep the budget out first


async def test_a_slot_wait_longer_than_the_budget_times_out_and_leaks_no_slot():
    limiter = Limiter(max_concurrency=1, host_interval_s=0)
    release = asyncio.Event()

    async def holder():
        async with limiter.slot("a.example", Budget(5)):
            await release.wait()

    task = asyncio.create_task(holder())
    await asyncio.sleep(0.01)
    with pytest.raises(StageTimeout) as caught:
        async with limiter.slot("b.example", Budget(0.1)):
            pass
    assert caught.value.stage == "waiting for a slot"
    release.set()
    await task
    async with limiter.slot("c.example", Budget(0.1)):  # the slot came back
        pass


async def test_yields_whether_the_fetch_had_to_wait():
    limiter = Limiter(max_concurrency=2, host_interval_s=0.05)
    async with limiter.slot("a.example", Budget(5)) as waited:
        assert waited is False
    async with limiter.slot("a.example", Budget(5)) as waited:
        assert waited is True
