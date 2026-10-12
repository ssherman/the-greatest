"""A redirect-cycle source that still owns a record must not be served.

Records and redirects are distilled independently, so a number whose redirect
is a cycle can still own a record from an older pass. The contract says a cycle
resolves to nothing, so `/oclc/{number}` answers 404 even then.
"""

import shutil

import duckdb
from fastapi.testclient import TestClient

from worldcat.api.deps import Settings, open_artifact
from worldcat.api.main import create_app
from worldcat.pipeline.paths import WorldcatPaths


def test_a_cycle_source_that_owns_a_stale_record_is_still_a_404(worldcat_artifact, tmp_path):
    shutil.copytree(
        worldcat_artifact.version_dir, tmp_path / "versions" / worldcat_artifact.dump_date
    )
    paths = WorldcatPaths(root=tmp_path, dump_date=worldcat_artifact.dump_date)
    records = paths.table("records")
    con = duckdb.connect()
    con.execute(
        f"COPY (SELECT * FROM (SELECT * REPLACE (9000000020 AS oclc) FROM '{records}' "
        f"WHERE oclc = 1055766559 UNION ALL SELECT * FROM '{records}') ORDER BY oclc) "
        f"TO '{records}' (FORMAT parquet)"
    )
    con.close()
    state = open_artifact(
        Settings(data_root=paths.root, data_version=paths.dump_date, temp_dir=tmp_path)
    )
    with TestClient(create_app(state)) as client:
        assert client.get("/oclc/9000000020").status_code == 404
        assert client.get("/oclc/1055766559").status_code == 200
