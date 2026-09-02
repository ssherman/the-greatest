import gzip
import shutil
from pathlib import Path

import pytest

FIXTURE_DIR = Path(__file__).parent / "fixtures"
DUMP_NAMES = ("works", "authors", "editions", "redirects", "ratings", "reading-log")
FIXTURE_DUMP_DATE = "2026-07-31"


@pytest.fixture(scope="session")
def fixture_dumps(tmp_path_factory) -> dict[str, Path]:
    """Gzip the committed fixture text into real dump filenames, once per session."""
    dest = tmp_path_factory.mktemp("ol-dumps") / FIXTURE_DUMP_DATE
    dest.mkdir(parents=True)
    paths = {}
    for name in DUMP_NAMES:
        source = FIXTURE_DIR / f"{name}.txt"
        target = dest / f"ol_dump_{name}_{FIXTURE_DUMP_DATE}.txt.gz"
        with source.open("rb") as fin, gzip.open(target, "wb") as fout:
            shutil.copyfileobj(fin, fout)
        paths[name] = target
    return paths
