"""The monthly build.

    1. download    six dumps, all agreeing on one date
    2. distill     each -> Parquet, via a single .gz scan into _staging
    3. derive      work_authors, year_evidence, popularity, transitive redirects
    4. validate    quality gates
    5. report      measured rows, bytes and timings
    6. promote     (operator step: point the API at the new version directory)

Staging survives a failed build so the intermediates can be inspected. A failed
gate leaves the previous version live: nothing here deletes an old version.
"""

from __future__ import annotations

import shutil
import time
from pathlib import Path

import typer

from .authors import build_authors, stage_authors
from .derive import build_popularity, build_work_authors, build_year_evidence
from .duck import connect
from .editions import build_editions, stage_editions
from .gates import gates_passed, run_gates
from .paths import ArtifactPaths
from .redirects import build_redirects
from .report import StageTimings, load_previous_report, write_build_report, write_manifest
from .works import build_works, stage_works

app = typer.Typer(add_completion=False)


class BuildFailed(RuntimeError):
    """A quality gate refused the build. The previous version stays live."""


def build(
    root: Path,
    *,
    dump_date: str | None = None,
    download: bool = True,
    memory_limit: str = "8GB",
    keep_staging: bool = False,
) -> dict:
    if download:
        from .download import download_all

        dump_date, _ = download_all(root)
    if dump_date is None:
        raise ValueError("dump_date is required when download is disabled")

    paths = ArtifactPaths(root=root, dump_date=dump_date)
    paths.ensure()
    timings = StageTimings()
    con = connect(paths, memory_limit=memory_limit)

    def stage(name: str, fn):
        started = time.time()
        result = fn()
        rows = result if isinstance(result, int) else None
        elapsed = time.time() - started
        timings.record(name, elapsed, rows=rows)
        suffix = f", {rows:,} rows" if rows else ""
        typer.echo(f"  {name}: {elapsed:.1f}s{suffix}")
        return result

    typer.echo(f"building {dump_date} in {paths.version_dir}")
    stage("works_staging", lambda: stage_works(con, paths))
    stage("works", lambda: build_works(con, paths)["works"])
    stage("authors_staging", lambda: stage_authors(con, paths))
    stage("authors", lambda: build_authors(con, paths)["authors"])
    stage("editions_staging", lambda: stage_editions(con, paths))
    stage("editions", lambda: build_editions(con, paths)["editions"])
    stage("work_authors", lambda: build_work_authors(con, paths))
    stage("redirects", lambda: build_redirects(con, paths)["redirects"])
    stage("year_evidence", lambda: build_year_evidence(con, paths))
    stage("popularity", lambda: build_popularity(con, paths))

    previous = load_previous_report(root, before_dump_date=dump_date)
    gate_results = run_gates(con, paths, previous_report=previous)
    for result in gate_results:
        typer.echo(f"  gate {result.name}: {result.status} -- {result.detail}")

    report = write_build_report(
        con, paths, dump_date=dump_date, gate_results=gate_results, timings=timings
    )
    write_manifest(paths, dump_date=dump_date, gate_results=gate_results, timings=timings)
    con.close()

    if not gates_passed(gate_results):
        raise BuildFailed(
            "quality gates failed; the previous version stays live and _staging is kept"
        )

    if not keep_staging and paths.staging_dir.exists():
        shutil.rmtree(paths.staging_dir)

    typer.echo(
        f"built {dump_date}: {report['total_bytes'] / 1e9:.2f} GB across "
        f"{len(report['tables'])} tables"
    )
    return report


@app.command()
def main(
    root: Path = typer.Option(Path("/home/shane/ol-data"), "--root"),  # noqa: B008
    dump_date: str | None = typer.Option(None, "--dump-date"),
    download: bool = typer.Option(True, "--download/--no-download"),
    memory_limit: str = typer.Option("8GB", "--memory-limit"),
    keep_staging: bool = typer.Option(False, "--keep-staging"),
) -> None:
    build(
        root,
        dump_date=dump_date,
        download=download,
        memory_limit=memory_limit,
        keep_staging=keep_staging,
    )


if __name__ == "__main__":
    app()
