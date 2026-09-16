from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths


def test_a_given_temp_directory_is_used_instead_of_paths_tmp_dir(tmp_path):
    """R66: a read-only artifact mount means `paths.tmp_dir` cannot be created.

    Passing `temp_directory` must point DuckDB's spill at that directory
    instead, and must never create or touch `paths.tmp_dir`.
    """
    paths = ArtifactPaths(root=tmp_path / "artifact-root", dump_date="2026-07-31")
    spill_dir = tmp_path / "spill"

    connection = connect(paths, memory_limit="512MB", temp_directory=spill_dir)
    try:
        (reported,) = connection.execute("SELECT current_setting('temp_directory')").fetchone()
        assert reported == str(spill_dir)
        assert not paths.tmp_dir.exists()
    finally:
        connection.close()


def test_no_temp_directory_keeps_the_original_behaviour(tmp_path):
    """`temp_directory=None` (the default) still mkdirs and uses `paths.tmp_dir`."""
    paths = ArtifactPaths(root=tmp_path / "artifact-root", dump_date="2026-07-31")

    connection = connect(paths, memory_limit="512MB")
    try:
        (reported,) = connection.execute("SELECT current_setting('temp_directory')").fetchone()
        assert reported == str(paths.tmp_dir)
        assert paths.tmp_dir.exists()
    finally:
        connection.close()
