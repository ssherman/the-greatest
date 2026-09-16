"""Configured DuckDB connections.

Three settings are not optional for a bulk pass:

  preserve_insertion_order=false  -- lets DuckDB stream without buffering row order
  memory_limit                    -- the editions pass will otherwise take the box down
  temp_directory                  -- the default spills into the root filesystem, and
                                     the editions pass spills tens of gigabytes

There is deliberately no `read_only` parameter. The artifact is Parquet read
through an in-memory connection, so there is no database file for DuckDB to open
read-only, and a flag that cannot enforce anything is worse than no flag: it
tells a future caller they are safe when they are not. What actually enforces
read-only is the container's `:ro` bind mount and never issuing a COPY against a
version directory.

`temp_directory` defaults to `paths.tmp_dir` (the pipeline's own spill
directory, under the artifact root). The API passes an explicit directory
instead: its artifact root is mounted read-only, so `paths.tmp_dir` cannot be
created there.
"""

from __future__ import annotations

from pathlib import Path

import duckdb

from .paths import ArtifactPaths


def connect(
    paths: ArtifactPaths,
    *,
    memory_limit: str = "8GB",
    threads: int | None = None,
    temp_directory: Path | None = None,
) -> duckdb.DuckDBPyConnection:
    connection = duckdb.connect(database=":memory:")
    connection.execute("SET preserve_insertion_order=false;")
    connection.execute(f"SET memory_limit='{memory_limit}';")
    spill_dir = paths.tmp_dir if temp_directory is None else temp_directory
    spill_dir.mkdir(parents=True, exist_ok=True)
    connection.execute(f"SET temp_directory='{spill_dir}';")
    if threads is not None:
        connection.execute(f"SET threads={threads};")
    return connection


def load_rows(
    con: duckdb.DuckDBPyConnection,
    table: str,
    columns: list[tuple[str, str]],
    rows: list[tuple],
) -> None:
    """Replace `table` with `rows`, via CREATE TEMP TABLE + parameterized INSERT.

    `con.register(name, list_of_dicts)` is rejected in this environment:
    DuckDB's Python replacement scan only accepts a pandas DataFrame, a
    DuckDBPyRelation, a pyarrow Table/Dataset/Scanner, or a NumPy ndarray --
    and despite the docstring's expectation, pyarrow is NOT actually present
    here (duckdb 1.5.5 does not pull it in transitively in this project's
    lockfile, confirmed via `uv run python -c "import pyarrow"` failing with
    ModuleNotFoundError). A parameterized `executemany` needs no extra
    dependency and binds list-typed columns (VARCHAR[]) correctly.

    TEMP, not a plain table (R82): the API runs one DuckDB cursor per request
    (see `openlibrary.api.deps.cursor`). Cursors opened from the same
    connection share the catalog for plain tables, but each cursor gets its
    own temp schema (verified) -- and the matcher's blocking/scoring queries
    load fixed scratch-table names (`q_ids`, `q_author_fps`, ...), so a plain
    `CREATE OR REPLACE TABLE` would let two concurrent requests race on the
    same name and read each other's rows. Semantics for the single-connection,
    single-threaded pipeline (which never has two cursors alive at once) are
    unchanged.
    """
    col_defs = ", ".join(f"{name} {sql_type}" for name, sql_type in columns)
    con.execute(f"CREATE OR REPLACE TEMP TABLE {table} ({col_defs})")
    if rows:
        placeholders = ", ".join(["?"] * len(columns))
        con.executemany(f"INSERT INTO {table} VALUES ({placeholders})", rows)
