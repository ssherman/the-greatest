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


@pytest.fixture(scope="session")
def fixture_artifact(tmp_path_factory, fixture_dumps):
    """Build the committed fixture corpus into a real artifact, once per session.

    Read-only for its consumers: several modules query the same ten Parquet
    tables, and building them per test costs a second each for no benefit.
    """
    from openlibrary.pipeline.build import build
    from openlibrary.pipeline.paths import ArtifactPaths

    root = tmp_path_factory.mktemp("ol-artifact")
    paths = ArtifactPaths(root=root, dump_date=FIXTURE_DUMP_DATE)
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    build(root, dump_date=FIXTURE_DUMP_DATE, download=False, memory_limit="1GB")
    return paths
