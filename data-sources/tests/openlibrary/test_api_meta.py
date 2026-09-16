import json
import shutil

import duckdb
import pytest
from fastapi.testclient import TestClient

from openlibrary.api.deps import (
    ConfigurationError,
    GatesFailed,
    MalformedArtifactFile,
    MissingTable,
    Settings,
    SymlinkedVersion,
    VersionMismatch,
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


def test_version_reports_the_dump_and_both_code_versions(client, fixture_artifact):
    body = client.get("/version").json()
    manifest = json.loads(fixture_artifact.manifest_path.read_text())
    assert body["source"] == "openlibrary"
    assert body["dump_date"] == "2026-07-31"
    # "Did the data change or did the code?" needs separate answers -- and
    # they must describe the ARTIFACT (R93), not merely whatever code happens
    # to be running (the fixture build was made by this running code, so the
    # manifest values equal the constants -- assert against the manifest to
    # prove that's what the field actually sources from).
    assert body["normalizer_version"] == manifest["normalizer_version"]
    assert body["pipeline_version"] == manifest["pipeline_version"]
    assert "matcher_version" in body


def test_version_reports_per_table_row_counts(client):
    body = client.get("/version").json()
    assert body["tables"]["works"]["rows"] > 0
    assert set(body["tables"]) >= {"works", "authors", "editions", "identifiers", "redirects"}


def test_version_reports_the_evaluation_scores_when_they_exist(client):
    body = client.get("/version").json()
    assert "eval" in body
    # `eval` is the CODE's calibration record (eval/thresholds.json), not
    # this artifact's gate run -- it names the matcher version it measured.
    assert body["eval"]["matcher_version"] == body["matcher_version"]


def test_version_exposes_the_per_gate_results_of_this_build(client):
    """R91: `gates` is the build's own per-gate outcome list from
    build_report.json -- on the fixture build (and the 2026-07-31 one)
    `evaluation_set` is `skipped`, which `gates_passed: true` alone hides."""
    body = client.get("/version").json()
    by_name = {gate["name"]: gate["status"] for gate in body["gates"]}
    assert by_name["row_counts"] == "pass"
    assert by_name["evaluation_set"] == "skipped"


def _copied_version(tmp_path, fixture_artifact):
    version_dir = tmp_path / "versions" / fixture_artifact.dump_date
    shutil.copytree(fixture_artifact.version_dir, version_dir)
    return ArtifactPaths(root=tmp_path, dump_date=fixture_artifact.dump_date)


def _settings(paths):
    return Settings(data_root=paths.root, data_version=paths.dump_date)


def test_a_version_without_a_manifest_refuses_to_boot(tmp_path, fixture_artifact):
    """R91: build.py writes manifest.json last; a directory with every table
    but no manifest is an unfinished build, not a version."""
    paths = _copied_version(tmp_path, fixture_artifact)
    paths.manifest_path.unlink()

    with pytest.raises(GatesFailed, match="manifest"):
        open_artifact(_settings(paths))


def test_a_gate_failed_version_refuses_to_boot_naming_the_version(tmp_path, fixture_artifact):
    """R91: build.py writes the manifest (gates_passed: false) and all ten
    tables BEFORE raising on a failed gate, so the directory looks complete."""
    paths = _copied_version(tmp_path, fixture_artifact)
    manifest = json.loads(paths.manifest_path.read_text())
    manifest["gates_passed"] = False
    paths.manifest_path.write_text(json.dumps(manifest))

    with pytest.raises(GatesFailed, match=fixture_artifact.dump_date):
        open_artifact(_settings(paths))


def test_a_manifest_without_the_gates_flag_refuses_to_boot(tmp_path, fixture_artifact):
    paths = _copied_version(tmp_path, fixture_artifact)
    manifest = json.loads(paths.manifest_path.read_text())
    del manifest["gates_passed"]
    paths.manifest_path.write_text(json.dumps(manifest))

    with pytest.raises(GatesFailed):
        open_artifact(_settings(paths))


def test_a_normalizer_version_mismatch_refuses_to_boot_naming_both_versions(
    tmp_path, fixture_artifact
):
    """R93: an artifact built by an older or newer image must not be served --
    /version and every envelope would misreport provenance, and the matcher
    would silently join on fingerprints the artifact computed with a
    different normalizer."""
    paths = _copied_version(tmp_path, fixture_artifact)
    manifest = json.loads(paths.manifest_path.read_text())
    manifest["normalizer_version"] = 999
    paths.manifest_path.write_text(json.dumps(manifest))

    with pytest.raises(VersionMismatch, match="normalizer_version") as exc_info:
        open_artifact(_settings(paths))
    assert "999" in str(exc_info.value)


def test_a_manifest_missing_the_pipeline_version_refuses_to_boot(tmp_path, fixture_artifact):
    paths = _copied_version(tmp_path, fixture_artifact)
    manifest = json.loads(paths.manifest_path.read_text())
    del manifest["pipeline_version"]
    paths.manifest_path.write_text(json.dumps(manifest))

    with pytest.raises(VersionMismatch, match="pipeline_version"):
        open_artifact(_settings(paths))


def test_a_malformed_build_report_fails_at_boot_not_per_request(tmp_path, fixture_artifact):
    """R91: build_report.json and eval/thresholds.json are read ONCE in
    `open_artifact`; a malformed file is a boot failure naming the file,
    never a 500 on every /version call."""
    paths = _copied_version(tmp_path, fixture_artifact)
    paths.report_path.write_text("{not json")

    with pytest.raises(MalformedArtifactFile, match="build_report.json"):
        open_artifact(_settings(paths))


def test_a_malformed_manifest_fails_at_boot(tmp_path, fixture_artifact):
    paths = _copied_version(tmp_path, fixture_artifact)
    paths.manifest_path.write_text("{not json")

    with pytest.raises(MalformedArtifactFile, match="manifest.json"):
        open_artifact(_settings(paths))


def test_the_report_is_read_once_at_boot(tmp_path, fixture_artifact):
    """Deleting build_report.json AFTER boot changes nothing: /version serves
    the tables and gates from `ArtifactState`, not from disk per request."""
    paths = _copied_version(tmp_path, fixture_artifact)
    state = open_artifact(_settings(paths))
    assert state.report["tables"]["works"]["rows"] > 0
    assert state.eval_thresholds["matcher_version"] == state.source_version.matcher_version
    paths.report_path.unlink()
    with TestClient(create_app(state)) as test_client:
        body = test_client.get("/version").json()
    assert body["tables"]["works"]["rows"] > 0
    assert body["gates"]


def test_boot_checks_run_in_order_tables_then_gates_then_weights(
    tmp_path, fixture_artifact, monkeypatch
):
    """symlink -> tables -> manifest/gates -> weights -> connect. A version
    that fails several checks reports the EARLIEST one: a missing table
    outranks a missing manifest, and a failed gate outranks a weights
    mismatch."""
    paths = _copied_version(tmp_path, fixture_artifact)
    paths.manifest_path.unlink()
    paths.table("popularity").unlink()
    with pytest.raises(MissingTable):
        open_artifact(_settings(paths))

    paths = _copied_version(tmp_path / "second", fixture_artifact)
    manifest = json.loads(paths.manifest_path.read_text())
    manifest["gates_passed"] = False
    paths.manifest_path.write_text(json.dumps(manifest))
    monkeypatch.setattr("openlibrary.api.deps.MATCHER_VERSION", 999)
    with pytest.raises(GatesFailed):
        open_artifact(_settings(paths))


def test_from_env_without_a_version_is_a_configuration_error_naming_it(monkeypatch):
    monkeypatch.delenv("OL_DATA_VERSION", raising=False)
    monkeypatch.setenv("OL_DATA_ROOT", "/data")

    with pytest.raises(ConfigurationError, match="OL_DATA_VERSION"):
        Settings.from_env()


def test_from_env_reads_every_variable(monkeypatch, tmp_path):
    monkeypatch.setenv("OL_DATA_ROOT", str(tmp_path))
    monkeypatch.setenv("OL_DATA_VERSION", "2026-07-31")
    monkeypatch.setenv("OL_API_MEMORY_LIMIT", "2GB")
    monkeypatch.setenv("OL_API_TEMP_DIR", str(tmp_path / "spill"))
    settings = Settings.from_env()
    assert settings.data_root == tmp_path
    assert settings.data_version == "2026-07-31"
    assert settings.memory_limit == "2GB"
    assert settings.temp_dir == tmp_path / "spill"


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
