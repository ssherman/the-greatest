"""Settings from the environment, the artifact opened at boot, per-request cursors."""

from __future__ import annotations

import contextlib
import json
import math
import os
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

import duckdb
from fastapi import Request

from worldcat.pipeline.paths import TABLES, WorldcatPaths
from worldcat.pipeline.report import PIPELINE_VERSION

SOURCE = "worldcat"


class ConfigurationError(RuntimeError): ...


class SymlinkedVersion(RuntimeError): ...


class MissingTable(RuntimeError): ...


class GatesFailed(RuntimeError): ...


class VersionMismatch(RuntimeError): ...


class MalformedArtifactFile(RuntimeError): ...


def _positive_env(name: str, parse, default):
    raw = os.environ.get(name, "")
    if raw == "":
        return default  # Compose forwards an unset host variable as ""
    try:
        value = parse(raw)
    except ValueError:
        value = None
    if value is None or not math.isfinite(value) or value <= 0:
        raise ConfigurationError(f"{name} must be a positive number, not {raw!r}")
    return value


@dataclass(frozen=True)
class Settings:
    data_root: Path
    data_version: str
    memory_limit: str = "2GB"
    temp_dir: Path = field(default_factory=lambda: Path(tempfile.gettempdir()))
    threads: int = 2
    deadline_s: float = 25.0

    @classmethod
    def from_env(cls) -> Settings:
        version = os.environ.get("WC_DATA_VERSION")
        if not version:
            raise ConfigurationError(
                "WC_DATA_VERSION is not set -- the API opens an explicit versions/<dump-date> "
                "and never guesses"
            )
        return cls(
            data_root=Path(os.environ.get("WC_DATA_ROOT") or "/data"),
            data_version=version,
            memory_limit=os.environ.get("WC_API_MEMORY_LIMIT") or "2GB",
            temp_dir=Path(os.environ.get("WC_API_TEMP_DIR") or tempfile.gettempdir()),
            threads=_positive_env("WC_API_THREADS", int, 2),
            deadline_s=_positive_env("WC_API_DEADLINE_S", float, 25.0),
        )


@dataclass
class ArtifactState:
    paths: WorldcatPaths
    connection: duckdb.DuckDBPyConnection
    manifest: dict
    report: dict
    deadline_s: float = 25.0


def _read_json(path: Path) -> dict:
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except ValueError as exc:
        raise MalformedArtifactFile(f"{path} is not valid JSON: {exc}") from None


def open_artifact(settings: Settings) -> ArtifactState:
    paths = WorldcatPaths(root=settings.data_root, dump_date=settings.data_version)
    if paths.version_dir.is_symlink():
        raise SymlinkedVersion(
            f"{paths.version_dir} is a symlink; point WC_DATA_VERSION at a real version directory"
        )
    for name in TABLES:
        if not paths.table(name).exists():
            raise MissingTable(f"version {settings.data_version} has no {name}.parquet")
    if not paths.manifest_path.exists():
        raise GatesFailed(
            f"version {settings.data_version} has no manifest.json "
            "-- an unfinished build is not a version"
        )
    manifest = _read_json(paths.manifest_path)
    if manifest.get("gates_passed") is not True:
        raise GatesFailed(
            f"version {settings.data_version} did not pass its quality gates "
            f"(manifest gates_passed={manifest.get('gates_passed')!r}); refusing to serve it"
        )
    if manifest.get("pipeline_version") != PIPELINE_VERSION:
        raise VersionMismatch(
            f"artifact pipeline_version {manifest.get('pipeline_version')!r} "
            f"!= running {PIPELINE_VERSION}"
        )
    report = _read_json(paths.report_path)
    settings.temp_dir.mkdir(parents=True, exist_ok=True)
    connection = duckdb.connect(database=":memory:")
    connection.execute(f"SET memory_limit='{settings.memory_limit}'")
    connection.execute(f"SET threads={settings.threads}")
    connection.execute(f"SET temp_directory='{settings.temp_dir}'")
    return ArtifactState(
        paths=paths,
        connection=connection,
        manifest=manifest,
        report=report,
        deadline_s=settings.deadline_s,
    )


def get_state(request: Request) -> ArtifactState:
    return request.app.state.artifact


@contextlib.contextmanager
def cursor(state: ArtifactState):
    """A per-request cursor. Never share the connection itself across threads."""
    handle = state.connection.cursor()
    try:
        yield handle
    finally:
        handle.close()
