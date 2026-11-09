"""Build the Wikidata artifact from the weekly JSON dump.

    python -m wikidata.pipeline.build --root /data --memory-limit 8GB --threads 6

Without --dump it discovers and downloads the newest dump and the redirect SQL. Distill writes
to `_staging`; the gates read it there; only a passing build promotes the tables into the
version directory and writes manifest.json (the completion marker, written last). A failing
build deletes the version directory and exits 1.

distill uses spawn multiprocessing, so this module must be run as `-m` / `__main__`.
"""

import json
import shutil
import time
from pathlib import Path

import httpx
import typer

from wikidata.pipeline import download as dl
from wikidata.pipeline.config import KeptConfig
from wikidata.pipeline.distill import distill
from wikidata.pipeline.gates import gates_passed, run_gates
from wikidata.pipeline.paths import TABLES, WikidataPaths
from wikidata.pipeline.report import (
    manifest_dict,
    table_stats,
    write_build_report,
    write_manifest,
)
from wikidata.pipeline.versions import read_status

app = typer.Typer(add_completion=False)


class BuildFailed(RuntimeError):
    """A quality gate refused the build."""


def _previous_counts(root: Path, dump_date: str) -> dict | None:
    earlier = [d for d in read_status(root).passing if d < dump_date]
    if not earlier:
        return None
    manifest = json.loads((root / "versions" / max(earlier) / "manifest.json").read_text())
    return manifest.get("tables")


def build(
    *,
    root: Path,
    memory_limit: str,
    threads: int,
    dump: Path | None = None,
    dump_date: str | None = None,
    redirect_sql: Path | None = None,
    page_sql: Path | None = None,
    redirects_dump_date: str | None = None,
    keep_dump: bool = False,
    fixture: bool = False,
    keep_failed_tables: bool = False,
    client: httpx.Client | None = None,
    config: KeptConfig | None = None,
) -> dict:
    config = config or KeptConfig.load()
    downloaded: Path | None = None
    timings: dict[str, float] = {}

    if dump is None:
        owned = client is None
        client = client or dl.make_client()
        try:
            found = dl.discover_latest(client)
            dump_date = found.dump_date
            dumps_dir = root / "dumps" / dump_date
            typer.echo(f"downloading {found.url}")
            started = time.time()
            downloaded = dump = dl.download(found, dumps_dir, client=client)
            redirect_sql, page_sql, redirects_dump_date = dl.download_redirect_sources(
                dumps_dir, client=client
            )
            timings["download"] = round(time.time() - started, 1)
        finally:
            if owned:
                client.close()
    if not (dump_date and redirect_sql and page_sql):
        raise typer.BadParameter("--dump needs --dump-date, --redirect-sql and --page-sql")

    paths = WikidataPaths(root=root, dump_date=dump_date)
    if dump_date in read_status(root).passing:
        raise typer.BadParameter(f"{dump_date} is already built")
    shutil.rmtree(paths.version_dir, ignore_errors=True)

    typer.echo(f"building {dump_date} in {paths.version_dir}")
    started = time.time()
    counts = distill(
        dump, redirect_sql, page_sql, paths, config, memory_limit=memory_limit, threads=threads
    )
    timings["distill"] = round(time.time() - started, 1)

    results = run_gates(paths, config, _previous_counts(root, dump_date), fixture=fixture)
    for result in results:
        typer.echo(f"  gate {result.name}: {result.status} -- {result.detail}")

    if not gates_passed(results):
        # Keep the report and a gates_passed=false manifest (the refresh script reads the
        # failed gate names from build_report.json); drop the tables to free the disk.
        write_build_report(
            paths,
            dump_date=dump_date,
            results=results,
            timings=timings,
            tables=table_stats(paths, staged=True),
        )
        write_manifest(paths, manifest_dict(dump_date, results, counts, redirects_dump_date))
        if keep_failed_tables:
            typer.echo(f"keeping the staged tables of the failed build in {paths.staging_dir}")
        else:
            shutil.rmtree(paths.staging_dir, ignore_errors=True)
        raise BuildFailed(f"quality gates failed for {dump_date}")

    for name in TABLES:
        paths.staged(name).replace(paths.table(name))
    shutil.rmtree(paths.staging_dir, ignore_errors=True)
    write_build_report(
        paths, dump_date=dump_date, results=results, timings=timings, tables=table_stats(paths)
    )
    manifest = manifest_dict(dump_date, results, counts, redirects_dump_date)
    write_manifest(paths, manifest)

    if downloaded is not None and not keep_dump:
        downloaded.unlink(missing_ok=True)
    typer.echo(f"built {dump_date}")
    return manifest


@app.command()
def main(
    root: Path = typer.Option(..., "--root"),  # noqa: B008
    dump: Path | None = typer.Option(None, "--dump", exists=True, dir_okay=False),  # noqa: B008
    dump_date: str | None = typer.Option(None, "--dump-date", help="required with --dump"),
    redirect_sql: Path | None = typer.Option(None, "--redirect-sql", exists=True),  # noqa: B008
    page_sql: Path | None = typer.Option(None, "--page-sql", exists=True),  # noqa: B008
    memory_limit: str = typer.Option("8GB", "--memory-limit"),
    threads: int = typer.Option(6, "--threads"),
    redirects_dump_date: str | None = typer.Option(None, "--redirects-dump-date"),
    keep_dump: bool = typer.Option(False, "--keep-dump"),
    fixture: bool = typer.Option(False, "--fixture", help="skip the real-dump canaries"),
    keep_failed_tables: bool = typer.Option(
        False,
        "--keep-failed-tables",
        help="diagnosis only: leave the staged tables when a gate fails (never servable)",
    ),
) -> None:
    try:
        build(
            root=root,
            dump=dump,
            dump_date=dump_date,
            redirect_sql=redirect_sql,
            page_sql=page_sql,
            redirects_dump_date=redirects_dump_date,
            memory_limit=memory_limit,
            threads=threads,
            keep_dump=keep_dump,
            fixture=fixture,
            keep_failed_tables=keep_failed_tables,
        )
    except BuildFailed as exc:
        typer.echo(str(exc), err=True)
        raise typer.Exit(1) from exc


if __name__ == "__main__":
    app()
