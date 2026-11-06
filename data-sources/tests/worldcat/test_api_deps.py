import json
import shutil
from pathlib import Path

import pytest

from worldcat.api.deps import (
    ConfigurationError,
    GatesFailed,
    MissingTable,
    Settings,
    SymlinkedVersion,
    VersionMismatch,
    open_artifact,
)
from worldcat.pipeline.paths import WorldcatPaths


def _settings(paths: WorldcatPaths, tmp_path: Path) -> Settings:
    return Settings(data_root=paths.root, data_version=paths.dump_date, temp_dir=tmp_path)


def _copied(tmp_path: Path, artifact: WorldcatPaths) -> WorldcatPaths:
    shutil.copytree(artifact.version_dir, tmp_path / "versions" / artifact.dump_date)
    return WorldcatPaths(root=tmp_path, dump_date=artifact.dump_date)


def test_from_env_reads_every_variable(monkeypatch):
    monkeypatch.setenv("WC_DATA_ROOT", "/srv/x")
    monkeypatch.setenv("WC_DATA_VERSION", "2025-09-04")
    monkeypatch.setenv("WC_API_MEMORY_LIMIT", "3GB")
    monkeypatch.setenv("WC_API_TEMP_DIR", "/tmp/wc")
    monkeypatch.setenv("WC_API_THREADS", "4")
    monkeypatch.setenv("WC_API_DEADLINE_S", "7.5")
    s = Settings.from_env()
    assert (s.data_root, s.data_version, s.memory_limit) == (Path("/srv/x"), "2025-09-04", "3GB")
    assert (s.temp_dir, s.threads, s.deadline_s) == (Path("/tmp/wc"), 4, 7.5)


def test_from_env_defaults_and_treats_empty_as_unset(monkeypatch):
    monkeypatch.setenv("WC_DATA_VERSION", "2025-09-04")
    monkeypatch.setenv("WC_API_THREADS", "")
    for name in ("WC_DATA_ROOT", "WC_API_MEMORY_LIMIT", "WC_API_DEADLINE_S"):
        monkeypatch.delenv(name, raising=False)
    s = Settings.from_env()
    assert (s.data_root, s.memory_limit, s.threads, s.deadline_s) == (Path("/data"), "2GB", 2, 25.0)


def test_from_env_without_a_version_is_a_configuration_error(monkeypatch):
    monkeypatch.delenv("WC_DATA_VERSION", raising=False)
    with pytest.raises(ConfigurationError, match="WC_DATA_VERSION"):
        Settings.from_env()


def test_a_gate_failed_version_refuses_to_boot(tmp_path, worldcat_artifact):
    paths = _copied(tmp_path, worldcat_artifact)
    manifest = json.loads(paths.manifest_path.read_text())
    manifest["gates_passed"] = False
    paths.manifest_path.write_text(json.dumps(manifest))
    with pytest.raises(GatesFailed, match=worldcat_artifact.dump_date):
        open_artifact(_settings(paths, tmp_path))


def test_a_missing_manifest_missing_table_symlink_and_old_pipeline_each_refuse(
    tmp_path, worldcat_artifact
):
    paths = _copied(tmp_path, worldcat_artifact)
    manifest = json.loads(paths.manifest_path.read_text())
    manifest["pipeline_version"] = 99
    paths.manifest_path.write_text(json.dumps(manifest))
    with pytest.raises(VersionMismatch):
        open_artifact(_settings(paths, tmp_path))
    paths.manifest_path.unlink()
    with pytest.raises(GatesFailed, match="manifest"):
        open_artifact(_settings(paths, tmp_path))
    paths.table("holdings").unlink()
    with pytest.raises(MissingTable, match="holdings"):
        open_artifact(_settings(paths, tmp_path))
    link_root = tmp_path / "linked"
    (link_root / "versions").mkdir(parents=True)
    (link_root / "versions" / "current").symlink_to(worldcat_artifact.version_dir)
    with pytest.raises(SymlinkedVersion):
        open_artifact(Settings(data_root=link_root, data_version="current", temp_dir=tmp_path))


def test_a_good_version_opens_with_the_manifest_and_report(tmp_path, worldcat_artifact):
    state = open_artifact(_settings(worldcat_artifact, tmp_path))
    try:
        assert state.manifest["gates_passed"] is True
        assert state.report["tables"]["records"]["rows"] > 0
        assert state.deadline_s == 25.0
        (one,) = state.connection.execute("SELECT 1").fetchone()
        assert one == 1
    finally:
        state.connection.close()


def test_api_imports_without_the_build_only_zstandard_extra():
    # The API image installs no extras. Blocking the module in a fresh
    # interpreter reproduces it; any API-side import of worldcat.pipeline.extract
    # (directly or through report/gates) would fail here.
    import subprocess
    import sys

    code = 'import sys; sys.modules["zstandard"] = None; import worldcat.api.main'
    result = subprocess.run([sys.executable, "-c", code], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
