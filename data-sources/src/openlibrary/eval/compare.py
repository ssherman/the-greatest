"""Compare two saved harness readings (`harness.write_reading`).

The before/after evaluation of the 2026-10-04 spec: the same labelled cases
scored by two matcher versions, side by side, plus every case whose decision
changed, so each new accept can be read by hand.
"""

from __future__ import annotations

import json
from pathlib import Path
from typing import Literal

import typer
from pydantic import BaseModel

app = typer.Typer(add_completion=False)

METRICS = (
    "precision_at_accept",
    "false_merge_rate",
    "false_reject_rate",
    "abstention_rate",
    "correct_no_match_rate",
    "canonical_rate",
    "list_row_abstention_rate",
    "list_row_false_merge_rate",
)

Change = Literal["newly_accepted", "newly_abstained", "newly_rejected", "key_changed"]


class DiffRow(BaseModel):
    case_id: str
    stratum: str
    change: Change
    before_verdict: str
    before_key: str | None
    after_verdict: str
    after_key: str | None
    expected_key: str | None
    after_correct: bool


def load_reading(path: Path) -> dict:
    return json.loads(Path(path).read_text())


def _values(source: dict) -> dict[str, float]:
    values = {name: source[name] for name in METRICS if name in source}
    recall = source.get("candidate_recall", {})
    if "10" in recall or 10 in recall:
        values["recall_at_10"] = recall.get("10", recall.get(10, 0.0))
    return values


def metric_rows(
    before: dict, after: dict, *, stratum: str | None = None
) -> list[tuple[str, float, float]]:
    b = _values(before["by_stratum"].get(stratum, {}) if stratum else before["metrics"])
    a = _values(after["by_stratum"].get(stratum, {}) if stratum else after["metrics"])
    return [
        (name, b.get(name, 0.0), a.get(name, 0.0))
        for name in (*METRICS, "recall_at_10")
        if name in b or name in a
    ]


def _change(before: dict, after: dict) -> Change:
    bv, av = before["decision"]["verdict"], after["decision"]["verdict"]
    if bv != av:
        return {
            "accept": "newly_accepted",
            "abstain": "newly_abstained",
            "reject": "newly_rejected",
        }[av]
    return "key_changed"


def decision_diff(before: dict, after: dict) -> list[DiffRow]:
    earlier = {o["case_id"]: o for o in before["outcomes"]}
    rows = []
    for later in after["outcomes"]:
        prior = earlier.get(later["case_id"])
        if prior is None:
            continue
        same_verdict = prior["decision"]["verdict"] == later["decision"]["verdict"]
        same_key = prior["decision"]["work_key"] == later["decision"]["work_key"]
        if same_verdict and (later["decision"]["verdict"] != "accept" or same_key):
            continue
        rows.append(
            DiffRow(
                case_id=later["case_id"],
                stratum=later["stratum"],
                change=_change(prior, later),
                before_verdict=prior["decision"]["verdict"],
                before_key=prior["decision"]["work_key"],
                after_verdict=later["decision"]["verdict"],
                after_key=later["decision"]["work_key"],
                expected_key=later["expected_work_key"],
                after_correct=later["correct"],
            )
        )
    return sorted(rows, key=lambda r: (r.change, r.stratum, r.case_id))


def _table(rows: list[tuple[str, float, float]]) -> list[str]:
    lines = ["| metric | before | after |", "|---|---|---|"]
    lines += [f"| {name} | {b:.4f} | {a:.4f} |" for name, b, a in rows]
    return lines


def render_markdown(before: dict, after: dict) -> str:
    out = [
        f"## Before: `{before['label']}` (matcher {before['matcher_version']}) · "
        f"After: `{after['label']}` (matcher {after['matcher_version']})",
        "",
        "### Overall",
        *_table(metric_rows(before, after)),
    ]
    for stratum in sorted(set(before["by_stratum"]) | set(after["by_stratum"])):
        out += ["", f"### {stratum}", *_table(metric_rows(before, after, stratum=stratum))]
    diff = decision_diff(before, after)
    out += [
        "",
        f"### Decision diff ({len(diff)} cases)",
        "",
        "| case | stratum | change | before | after | labelled | correct after | hand review |",
        "|---|---|---|---|---|---|---|---|",
    ]
    out += [
        f"| {r.case_id} | {r.stratum} | {r.change} | {r.before_verdict} {r.before_key or ''} | "
        f"{r.after_verdict} {r.after_key or ''} | {r.expected_key or ''} | {r.after_correct} | |"
        for r in diff
    ]
    return "\n".join(out) + "\n"


@app.command()
def main(
    before: Path = typer.Option(..., "--before"),  # noqa: B008
    after: Path = typer.Option(..., "--after"),  # noqa: B008
    out: Path = typer.Option(..., "--out"),  # noqa: B008
) -> None:
    text = render_markdown(load_reading(before), load_reading(after))
    out.parent.mkdir(parents=True, exist_ok=True)
    out.write_text(text)
    typer.echo(f"wrote {out}")


if __name__ == "__main__":
    app()
