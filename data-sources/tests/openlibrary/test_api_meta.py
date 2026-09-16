import shutil

import duckdb
import pytest
from fastapi.testclient import TestClient

from openlibrary.api.deps import (
    MissingTable,
    Settings,
    SymlinkedVersion,
    WeightsMismatch,
    open_artifact,
)
from openlibrary.api.main import create_app
from openlibrary.pipeline.paths import ArtifactPaths


@pytest.fixture(scope="module")
def client(fixture_artifact):
    state = open_artifact(
        Settings(data_root=fixture_artifact.root, data_version=fixture_artifact.dump_date)
    )
    with TestClient(create_app(state)) as test_client:
        yield test_client


def test_version_reports_the_dump_and_both_code_versions(client):
    body = client.get("/version").json()
    assert body["source"] == "openlibrary"
    assert body["dump_date"] == "2026-07-31"
    # "Did the data change or did the code?" needs separate answers.
    assert "normalizer_version" in body
    assert "pipeline_version" in body
    assert "matcher_version" in body


def test_version_reports_per_table_row_counts(client):
    body = client.get("/version").json()
    assert body["tables"]["works"]["rows"] > 0
    assert set(body["tables"]) >= {"works", "authors", "editions", "identifiers", "redirects"}


def test_version_reports_the_evaluation_scores_when_they_exist(client):
    body = client.get("/version").json()
    assert "eval" in body


def test_a_missing_table_refuses_to_boot(tmp_path, fixture_artifact):
    version_dir = tmp_path / "versions" / fixture_artifact.dump_date
    shutil.copytree(fixture_artifact.version_dir, version_dir)
    paths = ArtifactPaths(root=tmp_path, dump_date=fixture_artifact.dump_date)
    paths.table("popularity").unlink()

    with pytest.raises(MissingTable, match="popularity"):
        open_artifact(Settings(data_root=paths.root, data_version=paths.dump_date))


def test_a_symlinked_version_directory_refuses_to_boot(tmp_path, fixture_artifact):
    (tmp_path / "versions").mkdir()
    symlink = tmp_path / "versions" / fixture_artifact.dump_date
    symlink.symlink_to(fixture_artifact.version_dir, target_is_directory=True)

    with pytest.raises(SymlinkedVersion) as exc_info:
        open_artifact(Settings(data_root=tmp_path, data_version=fixture_artifact.dump_date))
    assert str(symlink) in str(exc_info.value)


def test_a_matcher_version_mismatch_refuses_to_boot(monkeypatch, fixture_artifact):
    monkeypatch.setattr("openlibrary.api.deps.MATCHER_VERSION", 999)

    with pytest.raises(WeightsMismatch):
        open_artifact(
            Settings(data_root=fixture_artifact.root, data_version=fixture_artifact.dump_date)
        )


def test_no_endpoint_accepts_a_write_method(client):
    for method in ("put", "patch", "delete"):
        response = getattr(client, method)("/version")
        assert response.status_code in (404, 405)


def test_the_connection_is_closed_when_the_app_shuts_down(fixture_artifact):
    state = open_artifact(
        Settings(data_root=fixture_artifact.root, data_version=fixture_artifact.dump_date)
    )
    with TestClient(create_app(state)):
        pass

    with pytest.raises(duckdb.ConnectionException):
        state.connection.execute("select 1")
