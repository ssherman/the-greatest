import duckdb
import pytest
from fastapi.testclient import TestClient

from worldcat.api.deps import Settings, open_artifact
from worldcat.api.main import create_app


@pytest.fixture(scope="module")
def client(worldcat_artifact, tmp_path_factory):
    state = open_artifact(
        Settings(
            data_root=worldcat_artifact.root,
            data_version=worldcat_artifact.dump_date,
            temp_dir=tmp_path_factory.mktemp("wc-tmp"),
        )
    )
    with TestClient(create_app(state)) as test_client:
        yield test_client


def test_version_reports_the_dump_and_the_gates(client):
    body = client.get("/version").json()
    assert body["source"] == "worldcat"
    assert body["dump_date"] == "2025-09-04"
    assert body["pipeline_version"] == 1
    assert body["gates_passed"] is True
    assert body["tables"]["records"] > 0
    assert {g["name"] for g in body["gates"]} >= {"row_counts", "canaries", "bad_frames"}
    assert len(body["source_fingerprint"]) == 64


def test_no_endpoint_accepts_a_write_method(client):
    for method in ("put", "patch", "delete"):
        assert getattr(client, method)("/version").status_code in (404, 405)


def test_the_connection_is_closed_when_the_app_shuts_down(worldcat_artifact, tmp_path):
    state = open_artifact(
        Settings(
            data_root=worldcat_artifact.root,
            data_version=worldcat_artifact.dump_date,
            temp_dir=tmp_path,
        )
    )
    with TestClient(create_app(state)):
        pass
    with pytest.raises(duckdb.ConnectionException):
        state.connection.execute("select 1")
