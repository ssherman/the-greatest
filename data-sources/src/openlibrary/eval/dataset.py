"""Load the evaluation set and compare work keys across dump versions.

A label written against 2026-07-31 may name a work that 2026-08-31 has merged
away. Comparison therefore resolves BOTH sides through redirects before deciding
whether two keys are the same work -- otherwise every monthly rebuild would show
a phantom regression.
"""

from __future__ import annotations

import collections
import unicodedata
from collections.abc import Iterable
from pathlib import Path

import duckdb
from pydantic import BaseModel, Field

from common.normalize import MIN_BLOCKING_FP_LENGTH, title_fingerprints
from openlibrary.eval.schema import EvalCase
from openlibrary.pipeline.duck import load_rows
from openlibrary.pipeline.paths import ArtifactPaths

CASES_DIR = Path(__file__).parent / "cases"


def load_cases(directory: Path | None = None, *, include_proposed: bool = False) -> list[EvalCase]:
    """Read every `*.jsonl` file in `directory` (default: `CASES_DIR`).

    A plain `agent` label is a proposal awaiting confirmation, not ground
    truth -- it is excluded unless `include_proposed=True`. The set's ground
    truth is human, `agent_confirmed` and `agent_researched` labels. Duplicate-id
    detection runs across every row read, proposals included, so a typo
    hiding behind an excluded proposal is still caught.
    """
    target = Path(directory) if directory else CASES_DIR
    cases: list[EvalCase] = []
    seen: set[str] = set()
    for path in sorted(target.glob("*.jsonl")):
        for line in path.read_text(encoding="utf-8").splitlines():
            if not line.strip():
                continue
            case = EvalCase.model_validate_json(line)
            if case.case_id in seen:
                raise ValueError(f"duplicate case_id {case.case_id!r} in {path}")
            seen.add(case.case_id)
            if include_proposed or case.label.labeled_by != "agent":
                cases.append(case)
    return cases


def stratum_counts(cases: Iterable[EvalCase]) -> dict[str, int]:
    return dict(collections.Counter(case.stratum for case in cases))


def verdict_counts(cases: Iterable[EvalCase]) -> dict[str, int]:
    return dict(collections.Counter(case.label.verdict for case in cases))


def resolve_keys(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    keys: Iterable[str],
) -> dict[str, str]:
    """Map each key to its terminal key, or to itself when it is not redirected."""
    wanted = [k for k in dict.fromkeys(keys) if k]
    if not wanted:
        return {}
    load_rows(con, "keys_to_resolve", [("work_key", "VARCHAR")], [(k,) for k in wanted])
    rows = con.execute(
        f"""
        SELECT k.work_key,
               COALESCE(r.terminal_key, k.work_key) AS terminal_key
        FROM keys_to_resolve k
        LEFT JOIN '{paths.table("redirects")}' r
          ON r.source_key = k.work_key AND r.entity = 'work' AND NOT r.is_cycle
        """
    ).fetchall()
    return {row[0]: row[1] for row in rows}


def same_work(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    left: str | None,
    right: str | None,
) -> bool:
    if not left or not right:
        return False
    resolved = resolve_keys(con, paths, [left, right])
    return resolved.get(left, left) == resolved.get(right, right)


def unknown_labeled_keys(
    con: duckdb.DuckDBPyConnection,
    paths: ArtifactPaths,
    cases: Iterable[EvalCase],
) -> list[tuple[str, str]]:
    """Labeled work keys that neither exist nor resolve. Usually a typed key."""
    labeled = [(c.case_id, c.label.work_key) for c in cases if c.label.work_key]
    if not labeled:
        return []
    resolved = resolve_keys(con, paths, [key for _, key in labeled])
    load_rows(
        con,
        "labeled_keys",
        [("case_id", "VARCHAR"), ("work_key", "VARCHAR")],
        [(cid, resolved.get(key, key)) for cid, key in labeled],
    )
    rows = con.execute(
        f"""
        SELECT l.case_id, l.work_key FROM labeled_keys l
        WHERE l.work_key NOT IN (SELECT work_key FROM '{paths.table("works")}')
        """
    ).fetchall()
    found_bad = {row[1] for row in rows}
    return [(cid, key) for cid, key in labeled if resolved.get(key, key) in found_bad]


class WorkFacts(BaseModel):
    work_key: str
    title: str | None = None
    title_fp: str = ""
    title_fp_noart: str = ""
    author_names: list[str] = Field(default_factory=list)
    author_fps: list[str] = Field(default_factory=list)
    edition_count: int = 0


def fetch_work_facts(
    con: duckdb.DuckDBPyConnection, paths: ArtifactPaths, keys: Iterable[str]
) -> dict[str, WorkFacts]:
    """Title variants, author names/fingerprints and edition count per work --
    what a duplicate claim is checked against and what a reviewer reads."""
    wanted = [k for k in dict.fromkeys(keys) if k]
    if not wanted:
        return {}
    load_rows(con, "facts_keys", [("work_key", "VARCHAR")], [(k,) for k in wanted])
    rows = con.execute(
        f"""
        WITH w AS (
          SELECT w.work_key, w.title, w.title_fp, w.title_fp_noart
          FROM facts_keys k JOIN '{paths.table("works")}' w USING (work_key)
        ),
        a AS (
          SELECT wa.work_key, list(DISTINCT an.name ORDER BY an.name) AS names,
                 list(DISTINCT an.name_fp ORDER BY an.name_fp) AS fps
          FROM facts_keys k
          JOIN '{paths.table("work_authors")}' wa USING (work_key)
          JOIN '{paths.table("author_names")}' an USING (author_key)
          WHERE an.name IS NOT NULL
          GROUP BY wa.work_key
        ),
        p AS (
          SELECT p.work_key, p.edition_count
          FROM facts_keys k JOIN '{paths.table("popularity")}' p USING (work_key)
        )
        SELECT w.work_key, w.title, w.title_fp, w.title_fp_noart,
               COALESCE(a.names, []), COALESCE(a.fps, []), COALESCE(p.edition_count, 0)
        FROM w LEFT JOIN a USING (work_key) LEFT JOIN p USING (work_key)
        """
    ).fetchall()
    return {
        r[0]: WorkFacts(
            work_key=r[0],
            title=r[1],
            title_fp=r[2] or "",
            title_fp_noart=r[3] or "",
            author_names=list(r[4]),
            author_fps=[fp for fp in r[5] if fp],
            edition_count=r[6],
        )
        for r in rows
    }


# NFKC, casefolded, all whitespace removed: "Q&a" and "Q & A" are the same raw title.
def _raw_title(title: str | None) -> str:
    return "".join(unicodedata.normalize("NFKC", title or "").casefold().split())


def _lossy(title: str | None) -> bool:
    """True when the fingerprint dropped letters: after folding accents, some
    alphabetic character is outside a-z (non-Latin scripts, l-stroke, o-slash...).
    Keep in step with the private copy in openlibrary/matcher/cluster.py."""
    decomposed = unicodedata.normalize("NFD", title or "")
    return any(
        c.isalpha() and not ("a" <= c.lower() <= "z")
        for c in decomposed
        if not unicodedata.combining(c)
    )


def _same_title(fp_a: str | None, fp_b: str | None, raw_a: str | None, raw_b: str | None) -> bool:
    """Equal fingerprints; one shorter than MIN_BLOCKING_FP_LENGTH, or lossy for either title,
    also needs equal raw titles. Keep in step with openlibrary/matcher/cluster.py."""
    if not fp_a or fp_a != fp_b:
        return False
    if len(fp_a) >= MIN_BLOCKING_FP_LENGTH and not (_lossy(raw_a) or _lossy(raw_b)):
        return True
    return bool(_raw_title(raw_a)) and _raw_title(raw_a) == _raw_title(raw_b)


def alternate_problems(
    label_key: str,
    alternate: str,
    facts: dict[str, WorkFacts],
    resolved: dict[str, str],
    *,
    case_title: str | None = None,
) -> list[str]:
    """Why `alternate` is not a verified duplicate of `label_key` ([] when it is).

    The title check passes on the labelled work's title (full or article-stripped) or on the
    case's own book title: Open Library's canonical work sometimes carries a variant title, and
    the list row asserts the real one. A fingerprint shorter than MIN_BLOCKING_FP_LENGTH counts
    only when the raw titles are also equal, so non-Latin titles that fingerprint to a digit
    do not match by accident."""
    if alternate == label_key:
        return ["alternate is the labelled key"]
    if resolved.get(alternate, alternate) == resolved.get(label_key, label_key):
        return ["redirects to the labelled work; not a duplicate"]
    if alternate not in facts:
        return ["not in works"]
    label, alt = facts.get(label_key), facts[alternate]
    if label is None:
        return ["labelled work not in works"]
    problems = []
    same_title = _same_title(label.title_fp, alt.title_fp, label.title, alt.title) or _same_title(
        label.title_fp_noart, alt.title_fp_noart, label.title, alt.title
    )
    if not same_title and case_title:
        case_fps = title_fingerprints(case_title)
        same_title = any(
            _same_title(case_fp, alt_fp, case_title, alt.title)
            for case_fp in (case_fps.full, case_fps.noart)
            for alt_fp in (alt.title_fp, alt.title_fp_noart)
        )
    if not same_title:
        problems.append("shares no title with the labelled work or the case title")
    if not set(label.author_fps) & set(alt.author_fps):
        problems.append("shares no author with the labelled work")
    return problems


def check_alternates(
    con: duckdb.DuckDBPyConnection, paths: ArtifactPaths, cases: Iterable[EvalCase]
) -> list[tuple[str, str, str]]:
    with_alternates = [c for c in cases if c.label.alternate_work_keys]
    keys = [k for c in with_alternates for k in (c.label.work_key, *c.label.alternate_work_keys)]
    resolved = resolve_keys(con, paths, keys)
    facts = fetch_work_facts(con, paths, [resolved.get(k, k) for k in keys])
    facts_by_original = {k: facts[resolved.get(k, k)] for k in keys if resolved.get(k, k) in facts}
    return [
        (case.case_id, alternate, problem)
        for case in with_alternates
        for alternate in case.label.alternate_work_keys
        for problem in alternate_problems(
            case.label.work_key,
            alternate,
            facts_by_original,
            resolved,
            case_title=case.book.title,
        )
    ]
