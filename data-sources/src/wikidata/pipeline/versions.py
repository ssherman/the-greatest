"""What the home server's refresh timer asks before and after a build.

    python -m wikidata.pipeline.versions next-action|status|prune --root /data

A passing version's manifest.json records `gates_passed: true`. A build that fails its gates
deletes its staged tables but keeps build_report.json and manifest.json (`gates_passed: false`),
so the refresh script can name the failed gates and the date is never rebuilt in a loop. A
failed directory is never served. A version directory with no manifest is a build that
never finished: neither passing nor failed, rebuilt and eventually pruned.
"""

import json
import shutil
from dataclasses import dataclass
from pathlib import Path

import typer

from wikidata.pipeline.download import discover_latest, make_client

app = typer.Typer(add_completion=False)


@dataclass(frozen=True)
class VersionStatus:
    passing: list[str]
    failed: list[str]
    incomplete: list[str]


def read_status(root: Path) -> VersionStatus:
    passing: list[str] = []
    failed: list[str] = []
    incomplete: list[str] = []
    versions_dir = root / "versions"
    if versions_dir.is_dir():
        for directory in sorted(d for d in versions_dir.iterdir() if d.is_dir()):
            try:
                manifest = json.loads((directory / "manifest.json").read_text())
            except (OSError, ValueError):
                incomplete.append(directory.name)
                continue
            if not isinstance(manifest, dict):
                incomplete.append(directory.name)
            elif manifest.get("gates_passed") is True:
                passing.append(directory.name)
            else:
                failed.append(directory.name)
    return VersionStatus(passing=passing, failed=failed, incomplete=incomplete)


def decide(latest: str, status: VersionStatus) -> str:
    if latest in status.passing:
        return f"skip built {latest}"
    if latest in status.failed:
        return f"skip failed {latest}"
    return f"build {latest}"


def prune(root: Path, *, keep: int, current: str | None) -> list[Path]:
    status = read_status(root)
    keep_versions = set(status.passing[-keep:]) if keep > 0 else set()
    if current:
        keep_versions.add(current)
    built = status.passing + status.failed
    newest_built = max(built) if built else None

    def superseded(date: str) -> bool:
        return newest_built is not None and date < newest_built

    doomed = [d for d in status.passing if d not in keep_versions]
    doomed += [d for d in status.failed + status.incomplete if superseded(d)]

    removed: list[Path] = []
    for date in sorted(doomed):
        path = root / "versions" / date
        shutil.rmtree(path)
        removed.append(path)

    dumps_dir = root / "dumps"
    if dumps_dir.is_dir():
        for directory in sorted(d for d in dumps_dir.iterdir() if d.is_dir()):
            if directory.name in status.passing or superseded(directory.name):
                shutil.rmtree(directory)
                removed.append(directory)
    return removed


@app.command("next-action")
def next_action_command(root: Path = typer.Option(..., "--root")) -> None:  # noqa: B008
    with make_client() as client:
        latest = discover_latest(client)
    typer.echo(decide(latest.dump_date, read_status(root)))


@app.command("status")
def status_command(root: Path = typer.Option(..., "--root")) -> None:  # noqa: B008
    status = read_status(root)
    typer.echo(
        json.dumps(
            {"passing": status.passing, "failed": status.failed, "incomplete": status.incomplete}
        )
    )


@app.command("prune")
def prune_command(
    root: Path = typer.Option(..., "--root"),  # noqa: B008
    keep: int = typer.Option(2, "--keep", min=1),
    current: str | None = typer.Option(None, "--current"),
) -> None:
    for path in prune(root, keep=keep, current=current):
        typer.echo(str(path))


if __name__ == "__main__":
    app()
