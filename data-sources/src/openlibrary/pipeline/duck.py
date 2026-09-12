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
