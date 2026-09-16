"""R79: the retrieval endpoints against the REAL 2026-07-31 artifact.

Skipped unless OL_DATA_ROOT and OL_DATA_VERSION are set -- see
test_eval_regression.py for the same pattern. `temp_dir=tmp_path` keeps
DuckDB's spill out of the read-only artifact root; nothing else here writes
under OL_DATA_ROOT.

Run with:
    OL_DATA_ROOT=/home/shane/ol-data OL_DATA_VERSION=2026-07-31 \\
        uv run pytest tests/openlibrary/test_api_artifact.py -m artifact -v -s

Timings are printed (via -s), not asserted: this is a smoke test against real
data, and the plan asks for wall-clock numbers in the task report rather than
a pinned performance budget here.
"""

from __future__ import annotations

import os
import time
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

from openlibrary.api.deps import Settings, open_artifact
from openlibrary.api.main import create_app
from openlibrary.eval.dataset import load_cases


@pytest.mark.artifact
def test_retrieval_endpoints_answer_from_the_real_artifact(tmp_path):
    root = os.environ.get("OL_DATA_ROOT")
    dump_date = os.environ.get("OL_DATA_VERSION")
    if not (root and dump_date):
        pytest.skip("set OL_DATA_ROOT and OL_DATA_VERSION")

    cases = sorted(load_cases(), key=lambda c: c.case_id)
    match_cases = [c for c in cases if c.label.verdict == "match" and c.label.work_key]
    assert match_cases, "the evaluation set has no match-labelled case with a work_key"
    case = match_cases[0]
    work_key = case.label.work_key

    isbn_case = next((c for c in match_cases if c.book.isbn13), None)

    state = open_artifact(Settings(data_root=Path(root), data_version=dump_date, temp_dir=tmp_path))
    timings: dict[str, float] = {}
    try:
        with TestClient(create_app(state)) as client:
            start = time.perf_counter()
            response = client.get(f"/works/{work_key}")
            timings["GET /works/{key}"] = time.perf_counter() - start
            assert response.status_code == 200
            data = response.json()["data"]
            assert data["title"]

            start = time.perf_counter()
            editions_response = client.get(f"/works/{work_key}/editions")
            timings["GET /works/{key}/editions"] = time.perf_counter() - start
            assert editions_response.status_code == 200

            if data["authors"]:
                author_key = data["authors"][0]["key"]["key"]
                start = time.perf_counter()
                author_response = client.get(f"/authors/{author_key}")
                timings["GET /authors/{key}"] = time.perf_counter() - start
                assert author_response.status_code == 200

                start = time.perf_counter()
                shelf_response = client.get(f"/authors/{author_key}/works?limit=50")
                timings["GET /authors/{key}/works?limit=50"] = time.perf_counter() - start
                assert shelf_response.status_code == 200
            else:
                timings["GET /authors/{key}"] = float("nan")
                timings["GET /authors/{key}/works?limit=50"] = float("nan")

            if isbn_case is not None:
                isbn = isbn_case.book.isbn13[0]
                start = time.perf_counter()
                identifier_response = client.get(f"/identifiers/isbn13/{isbn}")
                timings["GET /identifiers/isbn13/{value}"] = time.perf_counter() - start
                assert identifier_response.status_code == 200
            else:
                timings["GET /identifiers/isbn13/{value}"] = float("nan")
    finally:
        state.connection.close()

    print("\nReal-artifact retrieval timings (Task 31, R79):")
    for label, seconds in timings.items():
        print(f"  {label}: {seconds * 1000:.1f} ms")
