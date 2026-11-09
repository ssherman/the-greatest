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


def _best_rank(statements: list[dict]) -> list[dict]:
    """Like `wdt:`: the preferred statements if any exist, else the normal ones."""
    for rank in ("preferred", "normal"):
        chosen = [s for s in statements if s.get("rank", "normal") == rank]
        if chosen:
            return chosen
    return []


def _p800_works(cur, state: ArtifactState, targets: list[str]) -> list[tuple[str, str]]:
    """P800 is the author's own statement, so it lives in the target's claims, not in `links`."""
    rows = cur.execute(
        f"SELECT qid, claims FROM {_table(state, 'items')} WHERE qid IN ({_marks(targets)})",
        targets,
    ).fetchall()
    found = {r[0]: r[1] for r in rows}
    pairs = []
    for target in targets:
        if target not in found:
            continue
        for statement in _best_rank(json.loads(found[target]).get("P800", [])):
            value = statement.get("mainsnak", {}).get("datavalue", {}).get("value")
            if isinstance(value, dict) and str(value.get("id", "")).startswith("Q"):
                pairs.append((target, value["id"]))
    return pairs


def _exclusion(exclude_types: list[str]) -> str:
    if not exclude_types:
        return ""
    return f" AND NOT list_has_any(list_concat(i.types, i.forms), [{_marks(exclude_types)}])"


LINK_BATCH = 1000
P800_WORK_CAP = 5000


def _kept_labels(cur, state: ArtifactState, qids: list[str], exclude_types: list[str]) -> dict:
    """qid -> label for the qids that are kept items, labelled, and not of an excluded type.
    Both reads are literal IN lists on the sort key, so they prune to a few row groups."""
    kept = {
        r[0]
        for r in cur.execute(
            f"SELECT i.qid FROM {_table(state, 'items')} i WHERE i.qid IN ({_marks(qids)})"
            f"{_exclusion(exclude_types)}",
            [*qids, *exclude_types],
        ).fetchall()
    }
    if not kept:
        return {}
    wanted = [q for q in qids if q in kept]
    return {
        qid: label
        for qid, label in cur.execute(
            f"SELECT lb.qid, coalesce(lb.label_en, lb.label_mul)"
            f" FROM {_table(state, 'labels')} lb WHERE lb.qid IN ({_marks(wanted)})"
            " AND coalesce(lb.label_en, lb.label_mul) IS NOT NULL",
            wanted,
        ).fetchall()
    }


def _reverse_rows(
    cur, state: ArtifactState, target: str, properties: list[str], exclude_types: list[str], limit
) -> list[tuple[str, str, str]]:
    """(target, source, label) for sources linking to `target`, ordered by source. Reads
    `links` (filtered on target, a prefix of its sort key) in batches, then checks each
    batch's sources against items and labels by qid. The big tables are never joined on a
    column DuckDB cannot prune."""
    found: list[tuple[str, str, str]] = []
    after = ""
    while len(found) < limit:
        sources = [
            r[0]
            for r in cur.execute(
                f"SELECT DISTINCT source FROM {_table(state, 'links')}"
                f" WHERE property IN ({_marks(properties)}) AND target = ? AND source > ?"
                " ORDER BY source LIMIT ?",
                [*properties, target, after, LINK_BATCH],
            ).fetchall()
        ]
        if not sources:
            break
        meta = _kept_labels(cur, state, sources, exclude_types)
        found.extend((target, s, meta[s]) for s in sources if s in meta)
        after = sources[-1]
        if len(sources) < LINK_BATCH:
            break
    return found[:limit]


@router.post("/linked-from")
def linked_from(body: LinkedFromRequest, state: ArtifactState = Depends(get_state)) -> dict:
    """Sources must be kept items (present in `items`), which drops the scholarly articles
    and other unkept entities on both paths. Reads at most limit + 1 rows, enough to know
    whether the answer was truncated."""
    targets = _unique(body.targets)
    properties = _unique(body.properties)
    if not targets or not properties:
        return {"rows": [], "truncated": False}
    wanted = body.limit + 1
    rows: list[list[str]] = []
    seen: set[tuple[str, str]] = set()
    capped = False

    def add(batch) -> None:
        for target, source, label in batch:
            if (target, source) not in seen and len(rows) < wanted:
                seen.add((target, source))
                rows.append([target, source, label])

    with cursor(state) as cur:
        reverse = [p for p in properties if p != "P800"]
        for target in targets if reverse else []:
            if len(rows) >= wanted:
                break
            add(_reverse_rows(cur, state, target, reverse, body.exclude_types, wanted - len(rows)))
        if "P800" in properties and len(rows) < wanted:
            pairs = _p800_works(cur, state, targets)
            all_works = _unique([w for _, w in pairs])
            capped = len(all_works) > P800_WORK_CAP
            works = all_works[:P800_WORK_CAP]
            if works:
                meta = _kept_labels(cur, state, works, body.exclude_types)
                add((t, w, meta[w]) for t, w in pairs if w in meta)
    return {"rows": rows[: body.limit], "truncated": capped or len(rows) > body.limit}


def _name_qids(cur, state: ArtifactState, normalized: str) -> list[str]:
    return [
        r[0]
        for r in cur.execute(
            f"SELECT qid FROM {_table(state, 'names')} WHERE name = ?", [normalized]
        ).fetchall()
    ]


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
        qids = _name_qids(cur, state, normalized)
        if not qids:
            # Callers often carry a middle initial the Wikidata label lacks ("Douglas C.
            # Merrill"); retry once without single-letter tokens.
            tokens = normalized.split()
            reduced = [t for t in tokens if len(t) > 1]
            if len(reduced) >= 2 and len(reduced) < len(tokens):
                qids = _name_qids(cur, state, " ".join(reduced))
        if not qids:
            return {"hits": []}
        rows = cur.execute(
            "SELECT i.qid, coalesce(i.label_en, i.label_mul), i.description_en"
            f" FROM {_table(state, 'items')} i WHERE i.qid IN ({_marks(qids)})"
            " ORDER BY i.sitelink_count DESC, i.qid LIMIT ?",
            [*qids, limit],
        ).fetchall()
    return {"hits": [{"id": q_, "label": label, "description": desc} for q_, label, desc in rows]}
