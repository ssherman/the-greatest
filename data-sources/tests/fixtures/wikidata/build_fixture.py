"""Regenerates mini-all.json and mini-all.json.gz (the Wikidata dump fixture) from live Wikidata.

    cd data-sources && python tests/fixtures/wikidata/build_fixture.py [CACHE_DIR]

Authoring tool only: it hits the network (one request a second, cached in CACHE_DIR, default
/tmp/wikidata-fixture-cache) and is never run by pytest. Real entities (real QIDs, real statement
values) are trimmed hard; the Q9000xx and Q9100xx items are synthetic, built to prove one rule
each (edition, scholarly article, manga volume, 2-hop subclass chain, ranks/snaktypes/qualifiers).
"""

import gzip
import json
import sys
import time
import urllib.request
from pathlib import Path

import yaml

HERE = Path(__file__).resolve().parent
CACHE = Path(sys.argv[1] if len(sys.argv) > 1 else "/tmp/wikidata-fixture-cache")
USER_AGENT = "TheGreatest/1.0 (https://thegreatestbooks.org)"

_KEPT = yaml.safe_load((HERE.parent.parent.parent / "src/wikidata/kept.yml").read_text())
KEEP_PROPS = set(_KEPT["statement_properties"]) | set(_KEPT["external_ids"])
UNLISTED_KEEP = {"P18", "P646", "P1476"}  # kept only so tests can prove dropping
LANGS = {"en", "mul", "fr", "ru"}
ALWAYS_ALL = {"P31", "P279", "P7937"}  # class chains must not be truncated


def load(qid):
    CACHE.mkdir(parents=True, exist_ok=True)
    cached = CACHE / f"{qid}.json"
    if not cached.exists():
        url = f"https://www.wikidata.org/wiki/Special:EntityData/{qid}.json"
        request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        cached.write_bytes(urllib.request.urlopen(request).read())
        time.sleep(1)
    return json.loads(cached.read_text())["entities"][qid]


def trim(e):
    out = {"type": "item", "id": e["id"]}
    for k in ("labels", "descriptions"):
        out[k] = {la: v for la, v in e.get(k, {}).items() if la in LANGS}
    out["aliases"] = {la: v[:6] for la, v in e.get("aliases", {}).items() if la in LANGS}
    claims = {}
    for p, sts in e.get("claims", {}).items():
        if p in KEEP_PROPS or p in UNLISTED_KEEP:
            kept = sts if p in ALWAYS_ALL else sts[:3]
            claims[p] = [
                {k: s[k] for k in ("mainsnak", "type", "id", "rank", "qualifiers") if k in s}
                for s in kept
            ]
    out["claims"] = claims
    sl = e.get("sitelinks", {})
    keep = {}
    if "enwiki" in sl:
        keep["enwiki"] = sl["enwiki"]
    for k in list(sl)[:3]:
        keep.setdefault(k, sl[k])
    out["sitelinks"] = {
        k: {"site": v["site"], "title": v["title"], "badges": []} for k, v in keep.items()
    }
    return out


def stmt(prop, value, rank="normal", snaktype="value", dtype="wikibase-item", qualifiers=None):
    if snaktype == "value":
        if dtype == "wikibase-item":
            dv = {
                "value": {"entity-type": "item", "numeric-id": int(value[1:]), "id": value},
                "type": "wikibase-entityid",
            }
        elif dtype == "time":
            dv = {
                "value": {
                    "time": value,
                    "timezone": 0,
                    "before": 0,
                    "after": 0,
                    "precision": 9,
                    "calendarmodel": "http://www.wikidata.org/entity/Q1985727",
                },
                "type": "time",
            }
        else:
            dv = {"value": value, "type": "string"}
        ms = {"snaktype": "value", "property": prop, "datavalue": dv, "datatype": dtype}
    else:
        ms = {"snaktype": snaktype, "property": prop, "datatype": dtype}
    s = {"mainsnak": ms, "type": "statement", "rank": rank}
    if qualifiers:
        s["qualifiers"] = qualifiers
    return s


def synth(qid, label, desc, claims, aliases=None, sitelinks=None):
    return {
        "type": "item",
        "id": qid,
        "labels": {"en": {"language": "en", "value": label}},
        "descriptions": {"en": {"language": "en", "value": desc}} if desc else {},
        "aliases": {
            la: [{"language": la, "value": v} for v in vs] for la, vs in (aliases or {}).items()
        },
        "claims": claims,
        "sitelinks": {
            k: {"site": k, "title": t, "badges": []} for k, t in (sitelinks or {}).items()
        },
    }


ents = []

# Real entities, real ids, real statements, trimmed.
REAL = [
    "Q622400",  # Things Fall Apart (P31 Q7725634, P495 Q145, P50 Q155845)
    "Q155845",  # Chinua Achebe (P214 24596756, P27 Q1033)
    "Q1033",  # Nigeria (P297 NG)
    "Q145",  # United Kingdom (P297 GB)
    "Q6691",  # Homer
    "Q7243",  # Leo Tolstoy (ru label only)
    "Q12418",  # a painting: not kept, but its label must exist
    "Q1",
    "Q5",
    "Q571",
    "Q7725634",
    "Q8261",
    "Q8274",
    "Q3331189",
    "Q13442814",
    "Q21070568",
]
for q in REAL:
    entity = trim(load(q))
    if q == "Q7243":  # Cyrillic labels only
        entity["labels"] = {k: v for k, v in entity["labels"].items() if k == "ru"}
        entity["descriptions"] = {}
        entity["aliases"] = {k: v for k, v in entity["aliases"].items() if k == "ru"}
    ents.append(entity)

# Synthetic: an edition of Things Fall Apart, with a hyphenated ISBN-13 and a qualifier.
ents.append(
    synth(
        "Q900001",
        "Things Fall Apart (Anchor Books edition)",
        "1994 paperback edition",
        {
            "P31": [stmt("P31", "Q3331189")],
            "P629": [stmt("P629", "Q622400")],
            "P212": [stmt("P212", "978-0-385-47454-2", dtype="external-id")],
            "P577": [
                stmt(
                    "P577",
                    "+1994-09-01T00:00:00Z",
                    dtype="time",
                    qualifiers={
                        "P1810": [
                            {
                                "snaktype": "value",
                                "property": "P1810",
                                "datatype": "string",
                                "datavalue": {"value": "1994", "type": "string"},
                            }
                        ]
                    },
                )
            ],
        },
    )
)
# Synthetic: a scholarly article authored by Achebe (must not count as a work).
ents.append(
    synth(
        "Q900002",
        "Language and ethics in postcolonial fiction",
        "scholarly article",
        {
            "P31": [stmt("P31", "Q13442814")],
            "P50": [stmt("P50", "Q155845")],
            "P1476": [stmt("P1476", "Language and ethics", dtype="string")],
        },
    )
)
# Synthetic: a manga volume.
ents.append(
    synth(
        "Q900003",
        "Sample Manga, Volume 1",
        "manga volume",
        {
            "P31": [stmt("P31", "Q8274")],
            "P50": [stmt("P50", "Q900010")],
            "P407": [stmt("P407", "Q5287")],
        },
    )
)
ents.append(
    synth("Q900010", "Sample Mangaka", "Japanese manga artist", {"P31": [stmt("P31", "Q5")]})
)
# Synthetic: two-hop subclass chain. Q900005 -P31-> Q900004 -P279-> Q8261 (novel) -P279-> ... roots.
ents.append(
    synth("Q900004", "tide pool novel", "subgenre of novel", {"P279": [stmt("P279", "Q8261")]})
)
ents.append(
    synth(
        "Q900005",
        "The Tide Pool",
        "novel",
        {
            "P31": [stmt("P31", "Q900004")],
            "P50": [stmt("P50", "Q900006")],
            "P495": [stmt("P495", "Q1033")],
        },
    )
)
# Synthetic: an author with ranks, a somevalue snak, an unlisted property and a qualifier.
ents.append(
    synth(
        "Q900006",
        "Ada Example",
        "novelist",
        {
            "P31": [stmt("P31", "Q5")],
            "P569": [
                stmt("P569", "+1950-01-01T00:00:00Z", rank="preferred", dtype="time"),
                stmt("P569", "+1951-01-01T00:00:00Z", rank="deprecated", dtype="time"),
            ],
            "P570": [stmt("P570", None, snaktype="somevalue", dtype="time")],
            "P18": [stmt("P18", "Ada.jpg", dtype="commonsMedia")],
            "P27": [
                stmt(
                    "P27",
                    "Q1033",
                    qualifiers={
                        "P580": [{"snaktype": "somevalue", "property": "P580", "datatype": "time"}]
                    },
                )
            ],
        },
        aliases={"en": ["A. Example"], "de": ["Ada Beispiel"]},
        sitelinks={
            "enwiki": "Ada Example",
            "dewiki": "Ada Beispiel",
            "frwiki": "Ada Exemple",
            "eswiki": "Ada Ejemplo",
        },
    )
)

# Filler: unrelated synthetic items so the fixture has the shape of a real dump slice.
FILLER = [
    ("Lagos", "city in Nigeria"),
    ("Ibadan", "city in Nigeria"),
    ("Odysseus", "mythical Greek king"),
    ("Iliad", "epic poem"),
    ("Odyssey", "epic poem"),
    ("War and Peace", "novel by Tolstoy"),
    ("Anna Karenina", "novel by Tolstoy"),
    ("Igbo language", "language"),
    ("English", "language"),
    ("Russian", "language"),
    ("Yasnaya Polyana", "estate"),
    ("Starry Night", "painting"),
    ("Hamlet", "play"),
    ("Shakespeare", "playwright"),
    ("poem", "literary form"),
    ("epic", "genre"),
    ("manga", "comic genre"),
]
for i, (label, desc) in enumerate(FILLER):
    ents.append(
        synth(f"Q9100{i:02d}", label, desc, {"P31": [stmt("P31", "Q5")]} if i % 5 == 0 else {})
    )

# Dump format: "[", one entity per line ending in ",", "]".
dump = [json.dumps(e, ensure_ascii=False, separators=(",", ":")) for e in ents]
text = "[\n" + ",\n".join(dump) + "\n]\n"
(HERE / "mini-all.json").write_text(text)
with gzip.open(HERE / "mini-all.json.gz", "wt") as f:
    f.write(text)
print(len(ents), "entities")
