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
"""

from __future__ import annotations

import duckdb

from .paths import ArtifactPaths


def connect(
    paths: ArtifactPaths,
    *,
    memory_limit: str = "8GB",
    threads: int | None = None,
) -> duckdb.DuckDBPyConnection:
    connection = duckdb.connect(database=":memory:")
    connection.execute("SET preserve_insertion_order=false;")
    connection.execute(f"SET memory_limit='{memory_limit}';")
    paths.tmp_dir.mkdir(parents=True, exist_ok=True)
    connection.execute(f"SET temp_directory='{paths.tmp_dir}';")
    if threads is not None:
        connection.execute(f"SET threads={threads};")
    return connection


def load_rows(
    con: duckdb.DuckDBPyConnection,
    table: str,
    columns: list[tuple[str, str]],
    rows: list[tuple],
) -> None:
    """Replace `table` with `rows`, via CREATE TABLE + parameterized INSERT.

    `con.register(name, list_of_dicts)` is rejected in this environment:
    DuckDB's Python replacement scan only accepts a pandas DataFrame, a
    DuckDBPyRelation, a pyarrow Table/Dataset/Scanner, or a NumPy ndarray --
    and despite the docstring's expectation, pyarrow is NOT actually present
    here (duckdb 1.5.5 does not pull it in transitively in this project's
    lockfile, confirmed via `uv run python -c "import pyarrow"` failing with
    ModuleNotFoundError). A parameterized `executemany` needs no extra
    dependency and binds list-typed columns (VARCHAR[]) correctly.
    """
    col_defs = ", ".join(f"{name} {sql_type}" for name, sql_type in columns)
    con.execute(f"CREATE OR REPLACE TABLE {table} ({col_defs})")
    if rows:
        placeholders = ", ".join(["?"] * len(columns))
        con.executemany(f"INSERT INTO {table} VALUES ({placeholders})", rows)
