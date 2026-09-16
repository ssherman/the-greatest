"""Artifact lifecycle for a long-lived read-only process.

One connection per process, opened once at startup against an EXPLICIT version
directory. A cursor per request: DuckDB connections are not thread-safe, cursors
from one connection are, and they share the buffer pool so parquet metadata is
parsed once rather than per request.

The container mounts the artifact root read-only, so `paths.tmp_dir` (a
directory under that root) cannot be created or spilled into. `Settings.temp_dir`
points DuckDB's spill directory somewhere writable instead -- the API never
creates, mkdirs, or writes under the artifact root.
"""

from __future__ import annotations

import contextlib
import json
import os
import tempfile
from dataclasses import dataclass, field
from pathlib import Path

import duckdb
from fastapi import Request

from common.normalize import NORMALIZER_VERSION
from common.schemas import SourceVersion
from openlibrary.matcher.scorer import MATCHER_VERSION, Weights, load_weights
from openlibrary.pipeline.duck import connect as duck_connect
from openlibrary.pipeline.paths import TABLES, ArtifactPaths
from openlibrary.pipeline.report import PIPELINE_VERSION

SOURCE = "openlibrary"


class MissingTable(RuntimeError):
    """The version directory does not contain every table the API needs."""


class SymlinkedVersion(RuntimeError):
    """The version directory is a symlink.

    A symlink flip does not affect a process holding open file handles, so the
    API must be pointed at an explicit, real version directory.
    """


class WeightsMismatch(RuntimeError):
    """weights.json was calibrated for a different matcher version than is running."""


@dataclass(frozen=True)
class Settings:
    data_root: Path
    data_version: str
    memory_limit: str = "8GB"
    temp_dir: Path = field(default_factory=lambda: Path(tempfile.gettempdir()))

    @classmethod
    def from_env(cls) -> Settings:
        return cls(
            data_root=Path(os.environ.get("OL_DATA_ROOT", "/data")),
            data_version=os.environ["OL_DATA_VERSION"],
            memory_limit=os.environ.get("OL_API_MEMORY_LIMIT", "8GB"),
            temp_dir=Path(os.environ.get("OL_API_TEMP_DIR", tempfile.gettempdir())),
        )


@dataclass
class ArtifactState:
    paths: ArtifactPaths
    connection: duckdb.DuckDBPyConnection
    manifest: dict
    source_version: SourceVersion
    weights: Weights


def open_artifact(settings: Settings) -> ArtifactState:
    paths = ArtifactPaths(root=settings.data_root, dump_date=settings.data_version)

    if paths.version_dir.is_symlink():
        raise SymlinkedVersion(
            f"{paths.version_dir} is a symlink -- the API must open an explicit "
            "version directory, never a symlink that can flip under an open connection"
        )

    missing = [name for name in TABLES if not paths.table(name).exists()]
    if missing:
        raise MissingTable(f"version {settings.data_version} is missing: {', '.join(missing)}")

    weights = load_weights()
    if weights.matcher_version != MATCHER_VERSION:
        raise WeightsMismatch(
            f"weights.json was calibrated for matcher version {weights.matcher_version}, "
            f"but the running code is matcher version {MATCHER_VERSION}"
        )

    connection = duck_connect(
        paths, memory_limit=settings.memory_limit, temp_directory=settings.temp_dir
    )

    manifest = {}
    if paths.manifest_path.exists():
        manifest = json.loads(paths.manifest_path.read_text())

    return ArtifactState(
        paths=paths,
        connection=connection,
        manifest=manifest,
        source_version=SourceVersion(
            source=SOURCE,
            dump_date=settings.data_version,
            normalizer_version=NORMALIZER_VERSION,
            pipeline_version=PIPELINE_VERSION,
            matcher_version=MATCHER_VERSION,
        ),
        weights=weights,
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
