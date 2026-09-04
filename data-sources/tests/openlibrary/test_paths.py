from pathlib import Path

from openlibrary.pipeline.paths import TABLES, ArtifactPaths


def test_ten_tables_are_declared():
    assert TABLES == (
        "works",
        "work_details",
        "authors",
        "author_names",
        "work_authors",
        "editions",
        "identifiers",
        "year_evidence",
        "popularity",
        "redirects",
    )


def test_layout_is_version_scoped(tmp_path: Path):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    assert paths.version_dir == tmp_path / "versions" / "2026-07-31"
    assert paths.staging_dir == tmp_path / "versions" / "2026-07-31" / "_staging"
    assert paths.dumps_dir == tmp_path / "dumps" / "2026-07-31"
    assert paths.tmp_dir == tmp_path / "tmp"


def test_table_and_staging_paths_are_parquet(tmp_path: Path):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    assert paths.table("works").name == "works.parquet"
    assert paths.staging("works_raw").name == "works_raw.parquet"


def test_dump_path_uses_the_real_dump_filename(tmp_path: Path):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    assert paths.dump("reading-log").name == "ol_dump_reading-log_2026-07-31.txt.gz"


def test_ensure_creates_the_tree(tmp_path: Path):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    assert paths.version_dir.is_dir()
    assert paths.staging_dir.is_dir()
    assert paths.tmp_dir.is_dir()
    assert paths.dumps_dir.is_dir()
