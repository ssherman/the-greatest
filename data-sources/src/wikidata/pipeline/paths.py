"""The one owner of the Wikidata artifact's directory layout.

<root>/versions/<dump-date>/<table>.parquet
<root>/versions/<dump-date>/_staging/<table>.parquet   (distill writes here; Task 3 promotes)
<root>/versions/<dump-date>/manifest.json
<root>/versions/<dump-date>/build_report.json
<root>/tmp/                                            (DuckDB spill and pass-1 shards)
"""

from dataclasses import dataclass
from pathlib import Path

TABLES = ("items", "labels", "external_ids", "links", "names", "redirects")


@dataclass(frozen=True)
class WikidataPaths:
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
    def shards_dir(self) -> Path:
        return self.tmp_dir / "shards"

    @property
    def manifest_path(self) -> Path:
        return self.version_dir / "manifest.json"

    @property
    def report_path(self) -> Path:
        return self.version_dir / "build_report.json"

    def table(self, name: str) -> Path:
        return self.version_dir / f"{name}.parquet"

    def staged(self, name: str) -> Path:
        return self.staging_dir / f"{name}.parquet"

    def ensure(self) -> None:
        for directory in (self.version_dir, self.staging_dir, self.tmp_dir):
            directory.mkdir(parents=True, exist_ok=True)
