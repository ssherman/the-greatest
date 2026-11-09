"""The kept set: which entities, properties and identifiers survive the build.

Read from kept.yml so the build's kept set is one reviewable file that mirrors the Rails app's
written-work list.
"""

from dataclasses import dataclass
from pathlib import Path

import yaml

DEFAULT_PATH = Path(__file__).resolve().parent.parent / "kept.yml"


@dataclass(frozen=True)
class KeptConfig:
    work_roots: frozenset[str]
    edition_type: str
    person_types: frozenset[str]
    excluded_roots: frozenset[str]
    statement_properties: frozenset[str]
    external_ids: dict[str, str]
    reverse_links: frozenset[str]
    label_languages: tuple[str, ...]

    @classmethod
    def load(cls, path: Path | None = None) -> "KeptConfig":
        data = yaml.safe_load((path or DEFAULT_PATH).read_text())
        external_ids = {str(p): str(n) for p, n in data["external_ids"].items()}
        return cls(
            work_roots=frozenset(data["work_roots"]),
            edition_type=data["edition_type"],
            person_types=frozenset(data["person_types"]),
            excluded_roots=frozenset(data["excluded_roots"]),
            statement_properties=frozenset(data["statement_properties"]) | frozenset(external_ids),
            external_ids=external_ids,
            reverse_links=frozenset(data["reverse_links"]),
            label_languages=tuple(data["label_languages"]),
        )
