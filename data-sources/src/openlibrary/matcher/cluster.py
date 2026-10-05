"""Stage 2.5: duplicate clusters. Between scoring and deciding.

Open Library holds unmerged duplicate works -- the same title by the same
author -- that differ only in popularity, worth at most ~0.064 of score; no
margin could separate them (2026-10-04 spec, D3: 85 of 193 list-row abstains).
Two identity-bearing candidates are the same book when their full titles or
their article-stripped titles match (never subtitle-stripped, never one
against the other: "The Lord of the Rings: The Two Towers" and the omnibus
share a subtitle-stripped title), an author fingerprint is shared, and their
year agreement with the query does not diverge. A fingerprint shorter than
`MIN_BLOCKING_FP_LENGTH` (a non-Latin title shrunk to "6") counts only when
the raw titles are also equal. A cluster is represented by the member whose
identifier agrees, else by the member with the most editions when it
dominates the next by `duplicate_dominance_ratio`; real duplicates are stubs
beside one dominant work (Dune 160/3/1/1, Hamlet 2377/81/55), while different
books that share a title do not dominate (Dickinson's "Poems": 14/10/10).

Membership is joined pairwise, so A-B and B-C can join A and C even when A and
C diverge on year. That is accepted: the dominance rule is the backstop.
"""

from __future__ import annotations

import unicodedata
from collections import defaultdict
from dataclasses import dataclass

from pydantic import BaseModel, Field

from common.normalize import MIN_BLOCKING_FP_LENGTH, name_fingerprint
from openlibrary.matcher.features import WorkView
from openlibrary.matcher.scorer import ScoredCandidate, Weights, has_identity_evidence

YEAR_DIVERGENCE = 0.5


class ClusterInputs(BaseModel):
    title_fp: str = ""
    title_fp_noart: str = ""
    title_raw: str = ""
    author_fps: list[str] = Field(default_factory=list)
    edition_count: int = 0


def cluster_inputs(work: WorkView) -> ClusterInputs:
    return ClusterInputs(
        # Never title_fp_nosub (ruling 7).
        title_fp=work.title_fp,
        title_fp_noart=work.title_fp_noart,
        title_raw=work.title or "",
        author_fps=sorted({fp for fp in (name_fingerprint(n) for n in work.author_names) if fp}),
        edition_count=work.edition_count,
    )


@dataclass(frozen=True)
class ClusterIndex:
    of: dict[str, str]
    members: dict[str, list[str]]
    representative: dict[str, str | None]
    best_score: dict[str, float]


def _raw(title: str) -> str:
    # NFKC, casefolded, all whitespace removed: "Q&a" and "Q & A" are equal.
    return "".join(unicodedata.normalize("NFKC", title).casefold().split())


def _same_title(fp_a: str, fp_b: str, a: ClusterInputs, b: ClusterInputs) -> bool:
    if not fp_a or fp_a != fp_b:
        return False
    if len(fp_a) >= MIN_BLOCKING_FP_LENGTH:
        return True
    raw = _raw(a.title_raw)
    return bool(raw) and raw == _raw(b.title_raw)


def _same_book_title(a: ClusterInputs, b: ClusterInputs) -> bool:
    return _same_title(a.title_fp, b.title_fp, a, b) or _same_title(
        a.title_fp_noart, b.title_fp_noart, a, b
    )


def _value(candidate: ScoredCandidate, feature: str) -> float | None:
    return candidate.evidence.get(feature, {}).get("value")


def _years_agree(a: ScoredCandidate, b: ScoredCandidate) -> bool:
    ya, yb = _value(a, "year_agreement"), _value(b, "year_agreement")
    return ya is None or yb is None or abs(ya - yb) <= YEAR_DIVERGENCE


def _representative(
    members: list[str],
    by_key: dict[str, ScoredCandidate],
    inputs: dict[str, ClusterInputs],
    ratio: float,
) -> str | None:
    if len(members) == 1:
        return members[0]
    agreeing = [k for k in members if _value(by_key[k], "identifier_agreement") == 1.0]
    if len(agreeing) == 1:
        return agreeing[0]
    ordered = sorted(members, key=lambda k: (-inputs[k].edition_count, k))
    top, second = inputs[ordered[0]].edition_count, inputs[ordered[1]].edition_count
    if top > second and top >= ratio * second:
        return ordered[0]
    return None


def build_clusters(
    candidates: list[ScoredCandidate], inputs: dict[str, ClusterInputs], weights: Weights
) -> ClusterIndex:
    by_key = {c.work_key: c for c in candidates}
    parent = {c.work_key: c.work_key for c in candidates}

    def find(k: str) -> str:
        while parent[k] != k:
            parent[k] = parent[parent[k]]
            k = parent[k]
        return k

    eligible = [c for c in candidates if has_identity_evidence(c) and c.work_key in inputs]
    buckets: dict[tuple[str, str], list[str]] = defaultdict(list)
    for c in eligible:
        info = inputs[c.work_key]
        for kind, fp in (("full", info.title_fp), ("noart", info.title_fp_noart)):
            if fp:
                buckets[(kind, fp)].append(c.work_key)

    for keys in buckets.values():
        for i, a in enumerate(keys):
            for b in keys[i + 1 :]:
                if find(a) == find(b):
                    continue
                if not _same_book_title(inputs[a], inputs[b]):
                    continue
                if not set(inputs[a].author_fps) & set(inputs[b].author_fps):
                    continue
                if not _years_agree(by_key[a], by_key[b]):
                    continue
                ra, rb = find(a), find(b)
                parent[max(ra, rb)] = min(ra, rb)

    groups: dict[str, list[str]] = defaultdict(list)
    for c in candidates:
        groups[find(c.work_key)].append(c.work_key)
    members = {cid: sorted(keys) for cid, keys in groups.items()}
    return ClusterIndex(
        of={k: cid for cid, keys in members.items() for k in keys},
        members=members,
        representative={
            cid: _representative(keys, by_key, inputs, weights.duplicate_dominance_ratio)
            for cid, keys in members.items()
        },
        best_score={cid: max(by_key[k].score for k in keys) for cid, keys in members.items()},
    )
