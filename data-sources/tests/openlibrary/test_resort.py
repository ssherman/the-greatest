import shutil

import duckdb
import pytest

from openlibrary.pipeline.paths import ArtifactPaths
from openlibrary.pipeline.resort import BACKUP_DIR, STAGING_DIR, ResortError, install, stage
from openlibrary.pipeline.sort_order import SORT_KEYS, order_by


def _unsort(path, table) -> None:
    """Rewrite a table in reverse sort order, so it is certainly not sorted,
    like an artifact built before sort_order."""
    con = duckdb.connect()
    shuffled = path.with_suffix(".shuffled")
    reverse = ", ".join(f"{key} DESC" for key in SORT_KEYS[table])
    con.execute(
        f"COPY (SELECT * FROM '{path}' ORDER BY {reverse}) TO '{shuffled}' (FORMAT parquet)"
    )
    con.close()
    shuffled.replace(path)


def _file_order(path, table):
    con = duckdb.connect()
    rows = con.execute(
        f"SELECT {order_by(table)} FROM read_parquet('{path}', file_row_number = true) "
        "ORDER BY file_row_number"
    ).fetchall()
    con.close()
    return rows


def _contents(path):
    con = duckdb.connect()
    rows = sorted(con.execute(f"SELECT * FROM '{path}'").fetchall(), key=repr)
    con.close()
    return rows


@pytest.fixture()
def artifact(tmp_path, fixture_artifact):
    """A writable copy of the fixture artifact, its lookup tables unsorted."""
    paths = ArtifactPaths(root=tmp_path, dump_date=fixture_artifact.dump_date)
    shutil.copytree(fixture_artifact.version_dir, paths.version_dir)
    for table in SORT_KEYS:
        _unsort(paths.table(table), table)
        assert _file_order(paths.table(table), table) != sorted(
            _file_order(paths.table(table), table)
        )
    return paths


def test_stage_writes_sorted_copies_and_leaves_the_served_files_alone(artifact):
    before = {table: artifact.table(table).read_bytes() for table in SORT_KEYS}

    rows = stage(artifact, memory_limit="1GB")

    assert set(rows) == set(SORT_KEYS)
    for table in SORT_KEYS:
        staged = artifact.version_dir / STAGING_DIR / f"{table}.parquet"
        assert _file_order(staged, table) == sorted(_file_order(staged, table))
        assert _contents(staged) == _contents(artifact.table(table))
        assert rows[table] == len(_contents(staged))
        assert artifact.table(table).read_bytes() == before[table]


def test_install_swaps_the_staged_files_in_and_keeps_the_originals(artifact):
    originals = {table: artifact.table(table).read_bytes() for table in SORT_KEYS}
    stage(artifact, memory_limit="1GB")

    install(artifact)

    for table in SORT_KEYS:
        assert _file_order(artifact.table(table), table) == sorted(
            _file_order(artifact.table(table), table)
        )
        backup = artifact.version_dir / BACKUP_DIR / f"{table}.parquet"
        assert backup.read_bytes() == originals[table]
    assert not (artifact.version_dir / STAGING_DIR).exists()


def test_install_refuses_without_a_complete_staging(artifact):
    stage(artifact, memory_limit="1GB")
    (artifact.version_dir / STAGING_DIR / "works.parquet").unlink()
    served = {table: artifact.table(table).read_bytes() for table in SORT_KEYS}

    with pytest.raises(ResortError, match="works"):
        install(artifact)

    assert {table: artifact.table(table).read_bytes() for table in SORT_KEYS} == served


def test_install_refuses_a_staged_file_whose_row_count_differs(artifact):
    stage(artifact, memory_limit="1GB")
    staged = artifact.version_dir / STAGING_DIR / "redirects.parquet"
    con = duckdb.connect()
    con.execute(
        f"COPY (SELECT * FROM '{staged}' ORDER BY {order_by('redirects')} LIMIT 1) "
        f"TO '{staged}.tmp' (FORMAT parquet)"
    )
    con.close()
    staged.with_suffix(".parquet.tmp").replace(staged)

    with pytest.raises(ResortError, match="redirects"):
        install(artifact)


def test_install_refuses_to_overwrite_an_earlier_backup(artifact):
    stage(artifact, memory_limit="1GB")
    install(artifact)
    stage(artifact, memory_limit="1GB")

    with pytest.raises(ResortError, match=BACKUP_DIR):
        install(artifact)
