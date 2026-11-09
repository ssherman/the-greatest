import json
import shutil

import pytest

from wikidata.api.deps import (
    ConfigurationError,
    GatesFailed,
    Settings,
    open_artifact,
)
from wikidata.pipeline.paths import WikidataPaths


def _copied(tmp_path, artifact):
    shutil.copytree(artifact.version_dir, tmp_path / "versions" / artifact.dump_date)
    return WikidataPaths(root=tmp_path, dump_date=artifact.dump_date)


def _settings(paths, tmp_path):
    return Settings(data_root=paths.root, data_version=paths.dump_date, temp_dir=tmp_path)


def test_from_env_reads_every_variable(monkeypatch):
    monkeypatch.setenv("WD_DATA_ROOT", "/srv/x")
    monkeypatch.setenv("WD_DATA_VERSION", "2026-11-05")
    monkeypatch.setenv("WD_API_MEMORY_LIMIT", "3GB")
    monkeypatch.setenv("WD_API_THREADS", "4")
    s = Settings.from_env()
    assert (str(s.data_root), s.data_version, s.memory_limit, s.threads) == (
        "/srv/x",
        "2026-11-05",
        "3GB",
        4,
    )


def test_from_env_defaults(monkeypatch):
    monkeypatch.setenv("WD_DATA_VERSION", "2026-11-05")
    for name in ("WD_DATA_ROOT", "WD_API_MEMORY_LIMIT", "WD_API_THREADS"):
        monkeypatch.delenv(name, raising=False)
    s = Settings.from_env()
    assert (s.memory_limit, s.threads) == ("512MB", 2)


def test_from_env_without_a_version_is_a_configuration_error(monkeypatch):
    monkeypatch.delenv("WD_DATA_VERSION", raising=False)
    with pytest.raises(ConfigurationError, match="WD_DATA_VERSION"):
        Settings.from_env()


def test_no_manifest_refuses_to_boot(tmp_path, wikidata_artifact):
    paths = _copied(tmp_path, wikidata_artifact)
    paths.manifest_path.unlink()
    with pytest.raises(GatesFailed, match="manifest"):
        open_artifact(_settings(paths, tmp_path))


def test_a_gate_failed_version_refuses_to_boot(tmp_path, wikidata_artifact):
    paths = _copied(tmp_path, wikidata_artifact)
    manifest = json.loads(paths.manifest_path.read_text())
    manifest["gates_passed"] = False
    paths.manifest_path.write_text(json.dumps(manifest))
    with pytest.raises(GatesFailed, match=wikidata_artifact.dump_date):
        open_artifact(_settings(paths, tmp_path))


def test_the_connection_caches_parquet_metadata(tmp_path, wikidata_artifact):
    state = open_artifact(_settings(wikidata_artifact, tmp_path))
    (cached,) = state.connection.execute(
        "SELECT current_setting('parquet_metadata_cache')"
    ).fetchone()
    assert cached is True
    state.connection.close()


def test_a_passing_version_opens(tmp_path, wikidata_artifact):
    state = open_artifact(_settings(wikidata_artifact, tmp_path))
    assert state.manifest["gates_passed"] is True
    state.connection.close()
