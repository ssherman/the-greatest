"""Build the WorldCat artifact once from the Anna's Archive dump.

    uv run python -m worldcat.pipeline.build \
        --source "/mnt/e/annas archive worldcat/<aacid file>.jsonl.seekable.zst" \
        --root /home/shane/wc-data --dump-date 2025-09-04 --workers 8 --memory-limit 16GB \
        --catalogue-isbns /home/shane/wc-data/our_isbns.txt

Stages: extract (frame-parallel) -> records -> isbns -> redirects -> holdings ->
gates -> report + manifest. A failed gate raises BuildFailed, leaves _staging in
place for inspection, and writes gates_passed=false so the API refuses the
version. There is no download, refresh or promotion: the dump is frozen.

A build that dies after extract leaves its finished shards in _staging; `--resume`
builds from them instead of extracting again (an hour on the full dump). Without
it a build starts by deleting whatever an earlier run left there.
"""

import hashlib
import shutil
import time
from pathlib import Path

import typer

from worldcat.pipeline import distill
from worldcat.pipeline.extract import extract_all, load_progress
from worldcat.pipeline.gates import Thresholds, gates_passed, run_gates
from worldcat.pipeline.paths import WorldcatPaths
from worldcat.pipeline.report import StageTimings, write_build_report, write_manifest
from worldcat.pipeline.seektable import read_seek_table

app = typer.Typer(add_completion=False)


class BuildFailed(RuntimeError):
    """A quality gate refused the build."""


def source_fingerprint(source: Path) -> str:
    """sha256 over the file size, the first frame and the last frame: enough to
    tell two files apart without reading 281 GB."""
    frames = read_seek_table(source)
    digest = hashlib.sha256(str(source.stat().st_size).encode())
    with source.open("rb") as fh:
        for frame in (frames[0], frames[-1]):
            fh.seek(frame.offset)
            digest.update(fh.read(frame.compressed_size))
    return digest.hexdigest()


def _connect(paths: WorldcatPaths, memory_limit: str, threads: int | None):
    import duckdb

    con = duckdb.connect(database=":memory:")
    con.execute("SET preserve_insertion_order=false")
    con.execute(f"SET memory_limit='{memory_limit}'")
    con.execute(f"SET temp_directory='{paths.tmp_dir}'")
    if threads is not None:
        con.execute(f"SET threads={threads}")
    return con


def build(
    *,
    source: Path,
    root: Path,
    dump_date: str,
    workers: int = 8,
    memory_limit: str = "16GB",
    threads: int | None = None,
    keep_staging: bool = False,
    resume: bool = False,
    catalogue_isbns: Path | None = None,
    thresholds: Thresholds | None = None,
) -> dict:
    thresholds = thresholds or Thresholds()
    paths = WorldcatPaths(root=root, dump_date=dump_date)
    paths.ensure()
    if resume:
        resumed = load_progress(paths)  # raises ExtractIncomplete before anything is touched
    else:
        # A crashed or differently-sharded earlier run must not leak shards into this one.
        for stale in (
            *paths.staging_dir.glob("shard_*.parquet"),
            *paths.staging_dir.glob("progress_*.txt"),
        ):
            stale.unlink()
    timings = StageTimings()
    con = _connect(paths, memory_limit, threads)

    def stage(name: str, fn):
        started = time.time()
        result = fn()
        rows = result if isinstance(result, int) else None
        timings.record(name, time.time() - started, rows=rows)
        typer.echo(f"  {name}: {time.time() - started:.1f}s{f', {rows:,} rows' if rows else ''}")
        return result

    typer.echo(f"building {dump_date} in {paths.version_dir} from {source}")
    fingerprint = source_fingerprint(source)
    if resume:
        extract = resumed
        typer.echo(
            f"  extract: resumed from {len(extract)} finished workers,"
            f" {sum(s.kept for s in extract):,} rows"
        )
    else:
        extract = stage("extract", lambda: extract_all(source, paths, workers=workers))
        timings.record(
            "extract", timings.stages["extract"]["seconds"], rows=sum(s.kept for s in extract)
        )
    stage("records", lambda: distill.build_records(con, paths))
    stage("isbns", lambda: distill.build_isbns(con, paths))
    stage("redirects", lambda: distill.build_redirects(con, paths))
    stage("holdings", lambda: distill.build_holdings(con, paths))

    results = run_gates(
        con, paths, extract_stats=extract, thresholds=thresholds, catalogue_isbns=catalogue_isbns
    )
    for result in results:
        typer.echo(f"  gate {result.name}: {result.status} -- {result.detail}")
    report = write_build_report(
        con,
        paths,
        dump_date=dump_date,
        source_fingerprint=fingerprint,
        gate_results=results,
        timings=timings,
        extract=extract,
    )
    write_manifest(
        paths,
        dump_date=dump_date,
        source_fingerprint=fingerprint,
        gate_results=results,
        timings=timings,
        tables=report["tables"],
    )
    con.close()

    if not gates_passed(results):
        raise BuildFailed(
            "quality gates failed; _staging is kept and the manifest says gates_passed=false"
        )
    if not keep_staging and paths.staging_dir.exists():
        shutil.rmtree(paths.staging_dir)
    typer.echo(
        f"built {dump_date}: {report['total_bytes'] / 1e9:.2f} GB"
        f" across {len(report['tables'])} tables"
    )
    return report


@app.command()
def main(
    source: Path = typer.Option(..., "--source", exists=True, dir_okay=False),  # noqa: B008
    root: Path = typer.Option(Path("/home/shane/wc-data"), "--root"),  # noqa: B008
    dump_date: str = typer.Option("2025-09-04", "--dump-date"),
    workers: int = typer.Option(8, "--workers"),
    memory_limit: str = typer.Option("16GB", "--memory-limit"),
    threads: int | None = typer.Option(None, "--threads"),
    keep_staging: bool = typer.Option(False, "--keep-staging"),
    resume: bool = typer.Option(
        False, "--resume", help="distill the shards an earlier run left in _staging"
    ),
    catalogue_isbns: Path | None = typer.Option(  # noqa: B008
        None, "--catalogue-isbns", exists=True, dir_okay=False
    ),
) -> None:
    build(
        source=source,
        root=root,
        dump_date=dump_date,
        workers=workers,
        memory_limit=memory_limit,
        threads=threads,
        keep_staging=keep_staging,
        resume=resume,
        catalogue_isbns=catalogue_isbns,
    )


if __name__ == "__main__":
    app()
