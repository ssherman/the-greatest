from pathlib import Path

import pytest

from wikidata.pipeline.config import KeptConfig
from wikidata.pipeline.scan import iter_entities, slim

FIXTURE = Path(__file__).resolve().parent.parent / "fixtures" / "wikidata" / "mini-all.json"


@pytest.fixture(scope="module")
def slimmed():
    config = KeptConfig.load()
    return {e["id"]: slim(e, config) for e in iter_entities(FIXTURE)}


def _value(entity, prop, index=0):
    return entity.claims[prop][index]["mainsnak"]["datavalue"]["value"]


def test_the_real_canary_values_survive_slimming(slimmed):
    book = slimmed["Q622400"]
    assert book.types == ["Q7725634"]
    assert _value(book, "P495")["id"] == "Q145"
    assert _value(book, "P50")["id"] == "Q155845"
    achebe = slimmed["Q155845"]
    assert _value(achebe, "P214") == "24596756"
    assert "Q1033" in [s["mainsnak"]["datavalue"]["value"]["id"] for s in achebe.claims["P27"]]
    assert _value(slimmed["Q1033"], "P297") == "NG"
    assert _value(slimmed["Q145"], "P297") == "GB"
