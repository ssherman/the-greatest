from pathlib import Path

import pytest

from wikidata.pipeline.config import KeptConfig
from wikidata.pipeline.scan import iter_entities, slim

FIXTURES = Path(__file__).resolve().parent.parent / "fixtures" / "wikidata"


@pytest.fixture(scope="session")
def config():
    return KeptConfig.load()


@pytest.fixture(scope="session")
def slimmed(config):
    return {e["id"]: slim(e, config) for e in iter_entities(FIXTURES / "mini-all.json")}
