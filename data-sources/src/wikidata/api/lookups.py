"""Exact lookups over the artifact. Routes are sync `def` on purpose: DuckDB blocks, and
FastAPI runs sync routes in its threadpool.

Every query filters on its table's sort key with a literal IN list (never a subquery or a join
against the key), so DuckDB's zonemaps prune to the row groups that can hold the answer.
"""

import json

from fastapi import APIRouter, Depends, HTTPException, Query

from wikidata.api.deps import ArtifactState, cursor, get_state
from wikidata.api.schemas import (
    ExternalIdRequest,
    ItemsRequest,
    LabelsRequest,
    LinkedFromRequest,
)
from wikidata.pipeline.normalize import normalize_external_id, normalize_name

router = APIRouter()


def _marks(values: list) -> str:
    return ", ".join("?" for _ in values)


def _table(state: ArtifactState, name: str) -> str:
    return f"read_parquet('{state.paths.table(name)}')"


def _resolve(cur, state: ArtifactState, asked: list[str]) -> dict[str, str]:
    """asked qid -> surviving qid (itself unless a redirect row says otherwise)."""
    resolved = {qid: qid for qid in asked}
    if asked:
        rows = cur.execute(
            f"SELECT from_qid, to_qid FROM {_table(state, 'redirects')}"
            f" WHERE from_qid IN ({_marks(asked)})",
            asked,
        ).fetchall()
        resolved.update(dict(rows))
    return resolved


def _unique(values: list[str]) -> list[str]:
    return list(dict.fromkeys(values))


@router.post("/items")
def items(body: ItemsRequest, state: ArtifactState = Depends(get_state)) -> dict:
    asked = _unique(body.ids)
    dump_date = state.manifest.get("dump_date")
    with cursor(state) as cur:
        resolved = _resolve(cur, state, asked)
        targets = _unique(list(resolved.values()))
        rows = (
            cur.execute(
                "SELECT qid, labels, descriptions, aliases, claims, enwiki_title, sitelink_count"
                f" FROM {_table(state, 'items')} WHERE qid IN ({_marks(targets)})",
                targets,
            ).fetchall()
            if targets
            else []
        )
        entities = {}
        for qid, labels, descriptions, aliases, claims, enwiki, sitelink_count in rows:
            entities[qid] = {
                "id": qid,
                "labels": json.loads(labels),
                "descriptions": json.loads(descriptions),
                "aliases": json.loads(aliases),
                "claims": json.loads(claims),
                "sitelinks": {"enwiki": {"title": enwiki}} if enwiki else {},
                "sitelink_count": sitelink_count,
                "dump_date": dump_date,
            }
        absent = [qid for qid in targets if qid not in entities]
        known = (
            {
                r[0]
                for r in cur.execute(
                    f"SELECT qid FROM {_table(state, 'labels')} WHERE qid IN ({_marks(absent)})",
                    absent,
                ).fetchall()
            }
            if absent
            else set()
        )
    found, not_kept, missing = {}, [], []
    for qid in asked:
        target = resolved[qid]
        if target in entities:
            found[qid] = entities[target]
        elif target in known:
            not_kept.append(qid)
        else:
            missing.append(qid)
    return {"items": found, "not_kept": not_kept, "missing": missing}


@router.post("/labels")
def labels(body: LabelsRequest, state: ArtifactState = Depends(get_state)) -> dict:
    asked = _unique(body.ids)
    with cursor(state) as cur:
        resolved = _resolve(cur, state, asked)
        targets = _unique(list(resolved.values()))
        rows = (
            cur.execute(
                "SELECT qid, label_en, label_mul, description_en"
                f" FROM {_table(state, 'labels')} WHERE qid IN ({_marks(targets)})",
                targets,
            ).fetchall()
            if targets
            else []
        )
    by_qid = {qid: {"en": en, "mul": mul, "description": desc} for qid, en, mul, desc in rows}
    return {"labels": {qid: by_qid[resolved[qid]] for qid in asked if resolved[qid] in by_qid}}


@router.post("/by-external-id")
def by_external_id(body: ExternalIdRequest, state: ArtifactState = Depends(get_state)) -> dict:
    wanted: list[tuple[str, str]] = []
    for prop, value in body.pairs:
        kind = state.external_id_kinds.get(prop)
        if kind is None:
            raise HTTPException(422, f"{prop} is not an indexed external-id property")
        normalized = normalize_external_id(kind, value)
        if not normalized:
            continue
        # ISBN-10 and ISBN-13 are the same identifier under two properties; both are stored
        # as normalized ISBN-13, so a lookup under either property must search both.
        siblings = (
            [p for p, k in state.external_id_kinds.items() if k == "isbn"]
            if kind == "isbn"
            else [prop]
        )
        wanted.extend((p, normalized) for p in siblings)
    if not wanted:
        return {"ids": []}
    found: list[str] = []
    with cursor(state) as cur:
        # One query per property so the sort-key prefix (property, value) stays a plain IN.
        for prop in _unique([p for p, _ in wanted]):
            values = _unique([v for p, v in wanted if p == prop])
            rows = cur.execute(
                f"SELECT DISTINCT qid FROM {_table(state, 'external_ids')}"
                f" WHERE property = ? AND value IN ({_marks(values)}) ORDER BY qid LIMIT ?",
                [prop, *values, body.limit],
            ).fetchall()
            found.extend(r[0] for r in rows)
    return {"ids": _unique(found)[: body.limit]}


def _p800_works(cur, state: ArtifactState, targets: list[str]) -> list[tuple[str, str]]:
    """P800 is the author's own statement, so it lives in the target's claims, not in `links`."""
    rows = cur.execute(
        f"SELECT qid, claims FROM {_table(state, 'items')} WHERE qid IN ({_marks(targets)})",
        targets,
    ).fetchall()
    pairs = []
    for qid, claims in rows:
        for statement in json.loads(claims).get("P800", []):
            if statement.get("rank") == "deprecated":
                continue
            value = statement.get("mainsnak", {}).get("datavalue", {}).get("value")
            if isinstance(value, dict) and str(value.get("id", "")).startswith("Q"):
                pairs.append((qid, value["id"]))
    return pairs


@router.post("/linked-from")
def linked_from(body: LinkedFromRequest, state: ArtifactState = Depends(get_state)) -> dict:
    targets = _unique(body.targets)
    properties = _unique(body.properties)
    if not targets or not properties:
        return {"rows": [], "truncated": False}
    pairs: list[tuple[str, str]] = []
    with cursor(state) as cur:
        reverse = [p for p in properties if p != "P800"]
        if reverse:
            pairs.extend(
                cur.execute(
                    f"SELECT target, source FROM {_table(state, 'links')}"
                    f" WHERE property IN ({_marks(reverse)}) AND target IN ({_marks(targets)})"
                    " ORDER BY target, source",
                    [*reverse, *targets],
                ).fetchall()
            )
        if "P800" in properties:
            pairs.extend(_p800_works(cur, state, targets))
        pairs = _unique_pairs(pairs)
        sources = _unique([s for _, s in pairs])
        if not sources:
            return {"rows": [], "truncated": False}
        excluded = set()
        if body.exclude_types:
            excluded = {
                r[0]
                for r in cur.execute(
                    f"SELECT qid FROM {_table(state, 'items')}"
                    f" WHERE qid IN ({_marks(sources)})"
                    f" AND list_has_any(list_concat(types, forms), [{_marks(body.exclude_types)}])",
                    [*sources, *body.exclude_types],
                ).fetchall()
            }
        names = {
            qid: en or mul
            for qid, en, mul in cur.execute(
                f"SELECT qid, label_en, label_mul FROM {_table(state, 'labels')}"
                f" WHERE qid IN ({_marks(sources)})",
                sources,
            ).fetchall()
        }
    rows = [
        [target, source, names[source]]
        for target, source in pairs
        if source not in excluded and names.get(source)
    ]
    return {"rows": rows[: body.limit], "truncated": len(rows) > body.limit}


def _unique_pairs(pairs: list[tuple[str, str]]) -> list[tuple[str, str]]:
    return list(dict.fromkeys(pairs))


@router.get("/names")
def names(
    q: str = Query(min_length=1, max_length=200),
    limit: int = Query(default=10, ge=1, le=100),
    state: ArtifactState = Depends(get_state),
) -> dict:
    normalized = normalize_name(q)
    if not normalized:
        return {"hits": []}
    with cursor(state) as cur:
        qids = [
            r[0]
            for r in cur.execute(
                f"SELECT qid FROM {_table(state, 'names')} WHERE name = ?", [normalized]
            ).fetchall()
        ]
        if not qids:
            return {"hits": []}
        rows = cur.execute(
            "SELECT i.qid, coalesce(i.label_en, i.label_mul), i.description_en"
            f" FROM {_table(state, 'items')} i WHERE i.qid IN ({_marks(qids)})"
            " ORDER BY i.sitelink_count DESC, i.qid LIMIT ?",
            [*qids, limit],
        ).fetchall()
    return {"hits": [{"id": q_, "label": label, "description": desc} for q_, label, desc in rows]}
