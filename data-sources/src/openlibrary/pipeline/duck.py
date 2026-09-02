"""Configured DuckDB connections.

Three settings are not optional for a bulk pass:

  preserve_insertion_order=false  -- lets DuckDB stream without buffering row order
  memory_limit                    -- the editions pass will otherwise take the box down
  temp_directory                  -- the default spills into the root filesystem, and
                                     the editions pass spills tens of gigabytes
"""

from __future__ import annotations

import duckdb

from .paths import ArtifactPaths


def connect(
    paths: ArtifactPaths,
    *,
    memory_limit: str = "8GB",
    threads: int | None = None,
    read_only: bool = False,
) -> duckdb.DuckDBPyConnection:
    connection = duckdb.connect(database=":memory:", read_only=False)
    connection.execute("SET preserve_insertion_order=false;")
    connection.execute(f"SET memory_limit='{memory_limit}';")
    paths.tmp_dir.mkdir(parents=True, exist_ok=True)
    connection.execute(f"SET temp_directory='{paths.tmp_dir}';")
    if threads is not None:
        connection.execute(f"SET threads={threads};")
    if read_only:
        # The artifact is read through parquet scans; there is no attached database
        # to open read-only. The read-only guarantee is enforced by the container
        # mount (:ro) and by never issuing a COPY against the version directory.
        connection.execute("SET enable_external_access=true;")
    return connection
