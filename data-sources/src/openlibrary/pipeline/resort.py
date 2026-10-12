"""Re-sort the lookup tables of an artifact built before `sort_order`.

A build now writes `identifiers`, `works` and `redirects` sorted. This
rewrites them for a version directory that is already being served, without
the hours a rebuild and its gates cost. Sorting moves rows, never changes
them, so the manifest, the gates' verdict and the version's identity all stay
true.

Two steps, run through the compose `build` service (the `api` mounts the data
read-only):

  stage    writes sorted copies into <version>/_resorted/ and checks each one
           (row count, row-group order). The served files are untouched, so
           this can run while the API serves.
  install  re-checks the staged copies, moves the served files into
           <version>/_presort/ and the sorted ones into their place. Stop the
           API first: each table is briefly absent between its two renames.
           Start it again afterwards; `_presort/` is the rollback until it is
           deleted by hand.
"""

from __future__ import annotations

import contextlib
import os
from pathlib import Path

import duckdb
import typer

from .duck import connect
from .paths import ArtifactPaths
from .sort_order import SORT_KEYS, order_by, row_groups_in_order

STAGING_DIR = "_resorted"
BACKUP_DIR = "_presort"

app = typer.Typer(add_completion=False)


class ResortError(RuntimeError):
    """A staged file is missing or wrong, or an earlier install's backup is in the way."""


def _rows(con: duckdb.DuckDBPyConnection, path: Path) -> int:
    (rows,) = con.execute("SELECT count(*) FROM read_parquet(?)", [str(path)]).fetchone()
    return rows


def _check(con: duckdb.DuckDBPyConnection, paths: ArtifactPaths, table: str, staged: Path) -> int:
    rows = _rows(con, staged)
    served = _rows(con, paths.table(table))
    if rows != served:
        raise ResortError(f"{table}: staged copy has {rows:,} rows, the served file {served:,}")
    if not row_groups_in_order(con, staged, SORT_KEYS[table]):
        raise ResortError(f"{table}: staged copy is not in {order_by(table)} order")
    return rows


def stage(
    paths: ArtifactPaths, *, memory_limit: str = "8GB", threads: int | None = None
) -> dict[str, int]:
    """Write and check a sorted copy of each lookup table; return its row count."""
    staging = paths.version_dir / STAGING_DIR
    staging.mkdir(exist_ok=True)
    counts = {}
    con = connect(paths, memory_limit=memory_limit, threads=threads)
    with contextlib.closing(con):
        for table in SORT_KEYS:
            staged = staging / f"{table}.parquet"
            partial = staged.with_suffix(".partial")
            con.execute(
                f"COPY (SELECT * FROM read_parquet('{paths.table(table)}') "
                f"ORDER BY {order_by(table)}) TO '{partial}' (FORMAT parquet, COMPRESSION zstd)"
            )
            counts[table] = _check(con, paths, table, partial)
            partial.replace(staged)
    return counts


def install(paths: ArtifactPaths) -> None:
    """Swap every staged table in, keeping the served ones in BACKUP_DIR.
    Checks all of them before moving any."""
    staging = paths.version_dir / STAGING_DIR
    backup = paths.version_dir / BACKUP_DIR
    missing = [t for t in SORT_KEYS if not (staging / f"{t}.parquet").exists()]
    if missing:
        raise ResortError(f"nothing staged for {', '.join(missing)}; run stage first")
    in_the_way = [t for t in SORT_KEYS if (backup / f"{t}.parquet").exists()]
    if in_the_way:
        raise ResortError(
            f"{backup} already holds {', '.join(in_the_way)} from an earlier install; "
            "delete it once that install is confirmed good"
        )
    con = duckdb.connect()
    with contextlib.closing(con):
        for table in SORT_KEYS:
            _check(con, paths, table, staging / f"{table}.parquet")

    backup.mkdir(exist_ok=True)
    for table in SORT_KEYS:
        os.replace(paths.table(table), backup / f"{table}.parquet")
        os.replace(staging / f"{table}.parquet", paths.table(table))
    staging.rmdir()


def _paths(root: Path, dump_date: str) -> ArtifactPaths:
    paths = ArtifactPaths(root=root, dump_date=dump_date)
    if not paths.version_dir.is_dir():
        raise typer.BadParameter(f"{paths.version_dir} does not exist", param_hint="--dump-date")
    return paths


@app.command("stage")
def stage_command(
    root: Path = typer.Option(..., "--root"),  # noqa: B008
    dump_date: str = typer.Option(..., "--dump-date"),
    memory_limit: str = typer.Option("8GB", "--memory-limit"),
    threads: int | None = typer.Option(None, "--threads"),
) -> None:
    for table, rows in stage(
        _paths(root, dump_date), memory_limit=memory_limit, threads=threads
    ).items():
        typer.echo(f"staged {table}: {rows:,} rows, sorted by {order_by(table)}")


@app.command("install")
def install_command(
    root: Path = typer.Option(..., "--root"),  # noqa: B008
    dump_date: str = typer.Option(..., "--dump-date"),
) -> None:
    paths = _paths(root, dump_date)
    install(paths)
    typer.echo(
        f"installed sorted {', '.join(SORT_KEYS)}; originals in {paths.version_dir / BACKUP_DIR}"
    )


if __name__ == "__main__":
    app()
