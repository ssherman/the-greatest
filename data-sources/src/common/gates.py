"""Generic build-gate primitives, shared by every source."""

from __future__ import annotations

from dataclasses import dataclass, field


@dataclass(frozen=True)
class GateResult:
    name: str
    status: str  # "pass" | "fail" | "skipped"
    detail: str
    observed: dict = field(default_factory=dict)


def within_tolerance(
    previous: float | None,
    current: float,
    *,
    max_drop: float,
    max_rise: float,
) -> bool:
    """A first build has nothing to compare against and always passes.

    `max_drop` catches a truncated dump that parses cleanly; `max_rise` catches
    a duplicated join that quietly multiplied the corpus.
    """
    if previous is None or previous == 0:
        return True
    change = (current - previous) / previous
    return -max_drop <= change <= max_rise
