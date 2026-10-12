"""The one owner of the artifact's directory layout.

    <root>/versions/<dump-date>/<table>.parquet
    <root>/versions/<dump-date>/_staging/shard_<worker>_<index>.parquet   (deleted on success)
    <root>/versions/<dump-date>/manifest.json
    <root>/versions/<dump-date>/build_report.json
    <root>/tmp/                                                           (DuckDB spill)

There is no dumps/ directory: the source file is wherever the operator says
(--source) and is read once. The API opens an explicit <dump-date> directory,
never a symlink and never "the latest".
"""

from dataclasses import dataclass
from pathlib import Path

TABLES = ("records", "isbns", "redirects", "holdings")


@dataclass(frozen=True)
class WorldcatPaths:
    root: Path
    dump_date: str

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

    def shard(self, worker: int, index: int) -> Path:
        return self.staging_dir / f"shard_{worker:03d}_{index:05d}.parquet"

    def ensure(self) -> None:
        for directory in (self.version_dir, self.staging_dir, self.tmp_dir):
            directory.mkdir(parents=True, exist_ok=True)
