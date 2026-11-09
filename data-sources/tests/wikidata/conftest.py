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


WIKIDATA_DUMP_DATE = "2026-11-05"


@pytest.fixture(scope="session")
def wikidata_artifact(tmp_path_factory):
    """A real fixture build, once per session. Read-only for its consumers."""
    from wikidata.pipeline.build import build
    from wikidata.pipeline.paths import WikidataPaths

    root = tmp_path_factory.mktemp("wd-artifact")
    build(
        root=root,
        dump=FIXTURES / "mini-all.json",
        dump_date=WIKIDATA_DUMP_DATE,
        redirect_sql=FIXTURES / "mini-redirect.sql",
        page_sql=FIXTURES / "mini-page.sql",
        redirects_dump_date="2026-11-01",
        memory_limit="1GB",
        threads=2,
        fixture=True,
    )
    return WikidataPaths(root=root, dump_date=WIKIDATA_DUMP_DATE)


@pytest.fixture(scope="session")
def wikidata_client(wikidata_artifact, tmp_path_factory):
    from fastapi.testclient import TestClient

    from wikidata.api.deps import Settings, open_artifact
    from wikidata.api.main import create_app

    settings = Settings(
        data_root=wikidata_artifact.root,
        data_version=wikidata_artifact.dump_date,
        temp_dir=tmp_path_factory.mktemp("wd-tmp"),
    )
    with TestClient(create_app(open_artifact(settings))) as client:
        yield client
