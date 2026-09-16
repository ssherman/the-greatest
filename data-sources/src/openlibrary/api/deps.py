"""Artifact lifecycle for a long-lived read-only process.

One connection per process, opened once at startup against an EXPLICIT version
directory. A cursor per request: DuckDB connections are not thread-safe, cursors
from one connection are, and they share the buffer pool so parquet metadata is
parsed once rather than per request.

The container mounts the artifact root read-only, so `paths.tmp_dir` (a
directory under that root) cannot be created or spilled into. `Settings.temp_dir`
points DuckDB's spill directory somewhere writable instead -- the API never
creates, mkdirs, or writes under the artifact root.

`open_artifact` refuses to boot, in this order, on: a symlinked version
directory; a missing table; a missing manifest or one whose gates did not
pass (R91 -- `build.py` writes `manifest.json` with `gates_passed: false`
and all ten tables BEFORE raising on a failed gate, so a gate-failed
directory looks complete on disk); a weights/matcher version mismatch.
Only then does it connect. `build_report.json` and the code's
`eval/thresholds.json` are read ONCE here into `ArtifactState` so a
malformed file is a boot failure naming the file, never a 500 per request.
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


class GatesFailed(RuntimeError):
    """The version directory has no manifest (an unfinished build is not a
    version) or its manifest does not record `gates_passed: true`."""


class MalformedArtifactFile(RuntimeError):
    """manifest.json, build_report.json or eval/thresholds.json is not valid JSON."""


class ConfigurationError(RuntimeError):
    """A required environment variable is missing."""


THRESHOLDS_PATH = Path(__file__).resolve().parents[1] / "eval" / "thresholds.json"


@dataclass(frozen=True)
class Settings:
    data_root: Path
    data_version: str
    memory_limit: str = "8GB"
    temp_dir: Path = field(default_factory=lambda: Path(tempfile.gettempdir()))

    @classmethod
    def from_env(cls) -> Settings:
        data_version = os.environ.get("OL_DATA_VERSION")
        if not data_version:
            raise ConfigurationError(
                "OL_DATA_VERSION is not set -- the API opens an explicit version directory "
                "(versions/<dump-date>) and never guesses one"
            )
        return cls(
            data_root=Path(os.environ.get("OL_DATA_ROOT", "/data")),
            data_version=data_version,
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
    # build_report.json: this build's per-table stats and per-gate results.
    report: dict
    # eval/thresholds.json: the CODE's calibration record (pinned + measured
    # for the running matcher version), not this artifact's gate run.
    eval_thresholds: dict


def _read_json(path: Path) -> dict:
    """Read one JSON file at boot: `{}` if absent, a boot failure naming the
    file if malformed. (The manifest's absence is checked separately -- it
    is a `GatesFailed`, not an empty dict.)"""
    if not path.exists():
        return {}
    try:
        return json.loads(path.read_text())
    except json.JSONDecodeError as exc:
        raise MalformedArtifactFile(f"{path} is not valid JSON: {exc}") from exc


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

    if not paths.manifest_path.exists():
        raise GatesFailed(
            f"version {settings.data_version} has no manifest.json -- an unfinished build "
            "is not a version"
        )
    manifest = _read_json(paths.manifest_path)
    if manifest.get("gates_passed") is not True:
        raise GatesFailed(
            f"version {settings.data_version} did not pass its quality gates "
            f"(manifest gates_passed={manifest.get('gates_passed')!r}); refusing to serve it"
        )

    weights = load_weights()
    if weights.matcher_version != MATCHER_VERSION:
        raise WeightsMismatch(
            f"weights.json was calibrated for matcher version {weights.matcher_version}, "
            f"but the running code is matcher version {MATCHER_VERSION}"
        )

    # Read once, here: /version serves these from state, so a malformed
    # file fails the boot rather than every request.
    report = _read_json(paths.report_path)
    eval_thresholds = _read_json(THRESHOLDS_PATH)

    connection = duck_connect(
        paths, memory_limit=settings.memory_limit, temp_directory=settings.temp_dir
    )

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
        report=report,
        eval_thresholds=eval_thresholds,
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
