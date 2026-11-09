"""Streams the Wikidata JSON dump and slims each entity to what the build keeps.

The dump is one huge JSON array with one entity per line: "[", then "{...},", then "]". We never
parse the array, only lines.
"""

from collections.abc import Iterator
from dataclasses import dataclass
from pathlib import Path
from typing import IO, Any

import orjson
from isal import igzip_threaded

from wikidata.pipeline.config import KeptConfig


def _open(path: Path, threads: int) -> IO[bytes]:
    if path.suffix == ".gz":
        return igzip_threaded.open(path, "rb", threads=threads)
    return open(path, "rb")


def iter_entities(path: Path, *, threads: int = 4) -> Iterator[dict]:
    """Every entity of a .json.gz or .json dump, one per line."""
    with _open(Path(path), threads) as handle:
        for raw in handle:
            line = raw.strip()
            if line in (b"", b"[", b"]"):
                continue
            if line.endswith(b","):
                line = line[:-1]
            yield orjson.loads(line)


@dataclass
class SlimEntity:
    qid: str
    types: list[str]
    subclass_of: list[str]
    forms: list[str]
    labels: dict[str, Any]
    descriptions: dict[str, Any]
    aliases: dict[str, Any]
    all_names: list[str]
    claims: dict[str, list[dict]]
    enwiki_title: str | None
    sitelink_count: int


def _item_ids(claims: dict, prop: str) -> list[str]:
    ids = []
    for statement in claims.get(prop, []):
        value = statement.get("mainsnak", {}).get("datavalue", {}).get("value")
        if isinstance(value, dict) and "id" in value:
            ids.append(value["id"])
    return ids


def _slim_statement(statement: dict) -> dict:
    mainsnak = statement.get("mainsnak", {})
    slim_snak = {"snaktype": mainsnak.get("snaktype")}
    if "datavalue" in mainsnak:
        slim_snak["datavalue"] = mainsnak["datavalue"]
    return {"rank": statement.get("rank"), "mainsnak": slim_snak}


def slim(entity: dict, config: KeptConfig) -> SlimEntity:
    claims = entity.get("claims") or {}
    languages = config.label_languages
    labels = entity.get("labels") or {}
    aliases = entity.get("aliases") or {}

    names: dict[str, None] = {}
    for label in labels.values():
        names[label["value"]] = None
    for alias_list in aliases.values():
        for alias in alias_list:
            names[alias["value"]] = None

    sitelinks = entity.get("sitelinks") or {}
    enwiki = sitelinks.get("enwiki")

    return SlimEntity(
        qid=entity["id"],
        types=_item_ids(claims, "P31"),
        subclass_of=_item_ids(claims, "P279"),
        forms=_item_ids(claims, "P7937"),
        labels={lang: v for lang, v in labels.items() if lang in languages},
        descriptions={
            lang: v for lang, v in (entity.get("descriptions") or {}).items() if lang in languages
        },
        aliases={lang: v for lang, v in aliases.items() if lang in languages},
        all_names=list(names),
        claims={
            prop: [_slim_statement(s) for s in statements]
            for prop, statements in claims.items()
            if prop in config.statement_properties
        },
        enwiki_title=enwiki["title"] if enwiki else None,
        sitelink_count=len(sitelinks),
    )
