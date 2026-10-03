"""What the home server's refresh timer asks before and after a build.

The pipeline never decides whether to build or what to serve: the `ol` VM's
refresh script does (deployment/home-server/guest/ol-refresh.sh), by running
these commands inside this image:

    next-action   is the newest published dump new to this box?
    status        which versions passed, failed, or never finished
    prune         drop versions and dumps the box no longer needs

A version's own manifest.json records how its build went (`gates_passed`), so
there is no separate state file to drift from it.
"""

from __future__ import annotations

import json
import shutil
from dataclasses import asdict, dataclass
from pathlib import Path

import httpx
import typer

from .download import DumpDateMismatch, discover_all_dump_dates

app = typer.Typer(add_completion=False)


@dataclass(frozen=True)
class VersionStatus:
    passing: list[str]
    failed: list[str]
    # No readable manifest: a build that never finished. Rebuilt, never trusted.
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
                continue
            (passing if manifest.get("gates_passed") is True else failed).append(directory.name)
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
    # A failed or unfinished date keeps its _staging until a newer date builds
    # (passes or fails):
    # it is what explains the failure.
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
    try:
        with httpx.Client(timeout=30.0, follow_redirects=True) as client:
            dates = discover_all_dump_dates(client)
    except DumpDateMismatch as exc:
        # Open Library is mid-publication; tomorrow's run will see one date.
        typer.echo(f"skip mismatch {exc}")
        return
    typer.echo(decide(next(iter(dates.values())), read_status(root)))


@app.command("status")
def status_command(root: Path = typer.Option(..., "--root")) -> None:  # noqa: B008
    typer.echo(json.dumps(asdict(read_status(root))))


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
