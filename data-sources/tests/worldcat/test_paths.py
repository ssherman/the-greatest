from pathlib import Path

from worldcat.pipeline.paths import TABLES, WorldcatPaths


def test_layout_is_versions_slash_date(tmp_path: Path):
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    assert paths.version_dir == tmp_path / "versions" / "2025-09-04"
    assert paths.staging_dir == paths.version_dir / "_staging"
    assert paths.table("records") == paths.version_dir / "records.parquet"
    assert paths.shard(3, 7) == paths.staging_dir / "shard_003_00007.parquet"
    assert paths.manifest_path == paths.version_dir / "manifest.json"
    assert paths.tmp_dir == tmp_path / "tmp"


def test_ensure_creates_every_directory(tmp_path: Path):
    paths = WorldcatPaths(root=tmp_path, dump_date="2025-09-04")
    paths.ensure()
    for directory in (paths.version_dir, paths.staging_dir, paths.tmp_dir):
        assert directory.is_dir()


def test_tables_are_the_four_in_the_spec_plus_the_batch_lookup():
    assert TABLES == ("records", "isbns", "redirects", "holdings", "lookup")
