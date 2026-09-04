import pytest

from openlibrary.pipeline.build import build
from openlibrary.pipeline.paths import TABLES, ArtifactPaths


@pytest.fixture()
def artifact(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    report = build(tmp_path, dump_date="2026-07-31", download=False, memory_limit="1GB")
    return paths, report


def test_all_ten_tables_are_produced(artifact):
    paths, _ = artifact
    for table in TABLES:
        assert paths.table(table).exists(), table


def test_staging_is_removed_after_a_successful_build(artifact):
    paths, _ = artifact
    assert not paths.staging_dir.exists() or not any(paths.staging_dir.iterdir())


def test_report_and_manifest_are_written(artifact):
    paths, report = artifact
    assert paths.report_path.exists()
    assert paths.manifest_path.exists()
    assert report["dump_date"] == "2026-07-31"


def test_every_gate_passed_or_was_skipped(artifact):
    _, report = artifact
    assert [g for g in report["gates"] if g["status"] == "fail"] == []


def test_timings_cover_every_stage(artifact):
    _, report = artifact
    assert {
        "works",
        "authors",
        "editions",
        "work_authors",
        "redirects",
        "year_evidence",
        "popularity",
    } <= set(report["timings"])


def test_staging_is_kept_when_asked(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    build(tmp_path, dump_date="2026-07-31", download=False, memory_limit="1GB", keep_staging=True)
    assert any(paths.staging_dir.iterdir())
