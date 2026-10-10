"""What a published model says about itself, and the gate that decides
whether it replaces the previous one (spec 2 §4.3)."""

from __future__ import annotations

from datetime import UTC, datetime


def build(
    *,
    domain: str,
    export: str,
    lam: float,
    min_readers: int,
    top_k: int,
    users: int,
    items: int,
    rows: int,
    eval_result: dict,
    previous: str | None,
) -> dict:
    return {
        "domain": domain,
        "export": export,
        "trained_at": datetime.now(UTC).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "lambda": float(lam),
        "min_readers": int(min_readers),
        "top_k": int(top_k),
        "users": int(users),
        "items": int(items),
        "rows": int(rows),
        "eval": dict(eval_result),
        "previous": previous,
    }


def gate(new: dict, previous: dict | None, ratio: float) -> tuple[bool, str]:
    if previous is None:
        return True, "no previous model"
    old = (previous.get("eval") or {}).get("hit_at_10")
    if not old:
        return True, "previous model has no evaluation"
    fresh = new["eval"]["hit_at_10"]
    if fresh >= ratio * old:
        return True, f"hit@10 {fresh:.3f} vs previous {old:.3f}"
    return False, f"hit@10 {fresh:.3f} is below {ratio:.2f} x previous {old:.3f}"
