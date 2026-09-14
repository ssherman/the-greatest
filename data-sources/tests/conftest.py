import contextlib
import datetime
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


@pytest.fixture(scope="session")
def fixture_labelled_works(fixture_artifact) -> list[tuple[str, str, list[str]]]:
    """First 12 works (by work_key) with a unique, fingerprintable title and
    at least one author -- the shape the harness tests' metrics and forced
    false-merge tests build their cases from, and the shape the gate tests
    need for a labelled set whose works are PRESENT in the artifact (R50).
    Pinned with an explicit ORDER BY (ruling R43)."""
    from common.normalize import MIN_BLOCKING_FP_LENGTH
    from openlibrary.pipeline.duck import connect

    con = connect(fixture_artifact, memory_limit="1GB")
    with contextlib.closing(con):
        rows = con.execute(
            f"""
            SELECT w.work_key, w.title, list(DISTINCT a.name) AS names
            FROM '{fixture_artifact.table("works")}' w
            JOIN '{fixture_artifact.table("work_authors")}' wa USING (work_key)
            JOIN '{fixture_artifact.table("authors")}' a USING (author_key)
            WHERE w.title_fp <> '' AND length(w.title_fp) >= {MIN_BLOCKING_FP_LENGTH}
              AND w.title_fp_freq = 1 AND a.name IS NOT NULL
            GROUP BY w.work_key, w.title
            ORDER BY w.work_key
            LIMIT 12
            """
        ).fetchall()
    assert len(rows) >= 12, (
        "fixture corpus lost the uniquely-titled, authored works this test needs"
    )
    return [(work_key, title, list(names or [])) for work_key, title, names in rows]


@pytest.fixture(scope="session")
def fixture_labelled_cases(fixture_labelled_works) -> list:
    """Ten `match` cases labelled to real fixture works plus one `no_match`
    whose title blocks to nothing. Every labelled work exists in the fixture
    artifact, so R50's "not the labelled dump" skip does not fire."""
    from openlibrary.eval.schema import EvalBook, EvalCandidate, EvalCase, EvalLabel

    built = []
    for index, (work_key, title, names) in enumerate(fixture_labelled_works[:10], start=1):
        built.append(
            EvalCase(
                case_id=f"easy_baseline-{index:03d}",
                stratum="easy_baseline",
                book=EvalBook(book_id=index, title=title, author_names=list(names)),
                candidates_shown=[EvalCandidate(work_key=work_key, rules=["title_fp"])],
                label=EvalLabel(
                    verdict="match",
                    work_key=work_key,
                    identity_rule="same_work",
                    rationale="Constructed from the artifact for the harness test.",
                    labeled_at=datetime.date(2026, 9, 2),
                    labeled_against_dump_date=FIXTURE_DUMP_DATE,
                ),
            )
        )
    built.append(
        EvalCase(
            case_id="no_candidates-001",
            stratum="no_candidates",
            book=EvalBook(book_id=999, title="Zzzz Nothing Like This Exists Anywhere"),
            candidates_shown=[],
            label=EvalLabel(
                verdict="no_match",
                work_key=None,
                identity_rule="not_in_open_library",
                rationale="Checked Open Library by hand; nothing corresponds.",
                labeled_at=datetime.date(2026, 9, 2),
                labeled_against_dump_date=FIXTURE_DUMP_DATE,
            ),
        )
    )
    return built
