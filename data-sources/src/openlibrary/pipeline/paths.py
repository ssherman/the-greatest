"""The one place that knows the artifact directory layout.

    <root>/dumps/<dump-date>/ol_dump_<kind>_<dump-date>.txt.gz
    <root>/versions/<dump-date>/<table>.parquet
    <root>/versions/<dump-date>/_staging/<name>.parquet   (deleted on success)
    <root>/versions/<dump-date>/manifest.json
    <root>/versions/<dump-date>/build_report.json
    <root>/tmp/                                           (DuckDB spill)

The API is always pointed at an explicit <dump-date> directory, never a symlink:
a symlink flip does not affect a process holding open file handles.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

TABLES = (
    "works",
    "work_details",
    "authors",
    "author_names",
    "work_authors",
    "editions",
    "identifiers",
    "year_evidence",
    "popularity",
    "redirects",
)


@dataclass(frozen=True)
class ArtifactPaths:
    root: Path
    dump_date: str

    @property
    def dumps_dir(self) -> Path:
        return self.root / "dumps" / self.dump_date

    @property
    def version_dir(self) -> Path:
        return self.root / "versions" / self.dump_date

    @property
    def staging_dir(self) -> Path:
        return self.version_dir / "_staging"

    @property
    def tmp_dir(self) -> Path:
        return self.root / "tmp"

    @property
    def manifest_path(self) -> Path:
        return self.version_dir / "manifest.json"

    @property
    def report_path(self) -> Path:
        return self.version_dir / "build_report.json"

    def table(self, name: str) -> Path:
        return self.version_dir / f"{name}.parquet"

    def staging(self, name: str) -> Path:
        return self.staging_dir / f"{name}.parquet"

    def dump(self, kind: str) -> Path:
        return self.dumps_dir / f"ol_dump_{kind}_{self.dump_date}.txt.gz"

    def ensure(self) -> None:
        for directory in (self.dumps_dir, self.version_dir, self.staging_dir, self.tmp_dir):
            directory.mkdir(parents=True, exist_ok=True)
