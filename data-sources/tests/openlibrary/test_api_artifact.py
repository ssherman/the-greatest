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

from openlibrary.api.deps import Settings, cursor, open_artifact
from openlibrary.api.main import create_app
from openlibrary.eval.dataset import load_cases, resolve_keys


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


@pytest.mark.artifact
def test_batch_endpoints_answer_from_the_real_artifact(tmp_path):
    """R79/Task 32: POST /works/batch and POST /authors/batch against the real
    artifact -- one HTTP round trip standing in for what would otherwise be
    126,000 singular lookups. Timings are printed (via -s), not asserted; the
    report carries the wall-clock numbers."""
    root = os.environ.get("OL_DATA_ROOT")
    dump_date = os.environ.get("OL_DATA_VERSION")
    if not (root and dump_date):
        pytest.skip("set OL_DATA_ROOT and OL_DATA_VERSION")

    work_keys = sorted({c.label.work_key for c in load_cases() if c.label.work_key})[:100]
    assert len(work_keys) == 100, "the evaluation set has fewer than 100 labelled work keys"

    state = open_artifact(Settings(data_root=Path(root), data_version=dump_date, temp_dir=tmp_path))
    timings: dict[str, float] = {}
    try:
        with TestClient(create_app(state)) as client:
            start = time.perf_counter()
            response = client.post("/works/batch", json={"keys": work_keys})
            timings["POST /works/batch (100 keys)"] = time.perf_counter() - start
            assert response.status_code == 200
            data = response.json()["data"]
            assert set(data) == set(work_keys)
            non_null = [key for key in work_keys if data[key] is not None]
            assert len(non_null) >= 90, (
                f"only {len(non_null)}/100 labelled work keys resolved in this artifact"
            )

            author_keys = list(
                dict.fromkeys(
                    author["key"]["key"]
                    for key in work_keys[:20]
                    if data[key] is not None
                    for author in data[key]["authors"]
                )
            )
            start = time.perf_counter()
            author_response = client.post("/authors/batch", json={"keys": author_keys})
            timings["POST /authors/batch (authors of first 20 works)"] = time.perf_counter() - start
            assert author_response.status_code == 200
            assert set(author_response.json()["data"]) == set(author_keys)
    finally:
        state.connection.close()

    print("\nReal-artifact batch timings (Task 32, R79):")
    for label, seconds in timings.items():
        print(f"  {label}: {seconds * 1000:.1f} ms")
    print(f"  authors requested: {len(author_keys)} (from first 20 of the 100 works)")


@pytest.mark.artifact
def test_resolve_finds_the_labelled_work_for_an_easy_baseline_case(tmp_path):
    """R79/Task 33: one real POST /resolve, timed exactly as `eval.harness._query_for`
    builds its request, plus a second timed call for the plan's Gatsby query.
    Timings and the Gatsby verdict/top key are printed (via -s) for the task
    report, not asserted -- this is a smoke test against real data, not a
    pinned performance budget."""
    root = os.environ.get("OL_DATA_ROOT")
    dump_date = os.environ.get("OL_DATA_VERSION")
    if not (root and dump_date):
        pytest.skip("set OL_DATA_ROOT and OL_DATA_VERSION")

    cases = sorted(load_cases(), key=lambda c: c.case_id)
    case = next(
        (
            c
            for c in cases
            if c.stratum == "easy_baseline" and c.label.verdict == "match" and c.label.work_key
        ),
        None,
    )
    assert case is not None, "the evaluation set has no easy_baseline match-labelled case"
    book = case.book
    request_body = {
        "title": book.title,
        "subtitle": book.subtitle,
        "author_names": book.author_names,
        "year": book.first_published_year,
        "isbn13": book.isbn13,
        "isbn10": book.isbn10,
        "asin": book.asin,
        "goodreads_id": book.goodreads_id,
        "existing_ol_key": book.existing_ol_work_keys[0] if book.existing_ol_work_keys else None,
        "limit": 50,
    }

    state = open_artifact(Settings(data_root=Path(root), data_version=dump_date, temp_dir=tmp_path))
    timings: dict[str, float] = {}
    try:
        with TestClient(create_app(state)) as client:
            start = time.perf_counter()
            response = client.post("/resolve", json=request_body)
            timings["POST /resolve (easy_baseline case)"] = time.perf_counter() - start
            assert response.status_code == 200
            data = response.json()["data"]
            returned_keys = [candidate["key"]["key"] for candidate in data["candidates"]]

            # The label may name a redirect SOURCE (module docstring): compare
            # terminal keys via one `resolve_keys` call, not string equality.
            with cursor(state) as cur:
                resolved = resolve_keys(cur, state.paths, [case.label.work_key, *returned_keys])
            target_terminal = resolved.get(case.label.work_key, case.label.work_key)
            returned_terminals = {resolved.get(key, key) for key in returned_keys}
            assert target_terminal in returned_terminals, (
                f"labelled work {case.label.work_key} (terminal {target_terminal}) not among "
                f"the {len(returned_keys)} candidates /resolve returned"
            )

            start = time.perf_counter()
            gatsby_response = client.post(
                "/resolve",
                json={
                    "title": "The Great Gatsby",
                    "author_names": ["F. Scott Fitzgerald"],
                    "year": 1925,
                },
            )
            timings["POST /resolve (Gatsby)"] = time.perf_counter() - start
            assert gatsby_response.status_code == 200
            gatsby_data = gatsby_response.json()["data"]
    finally:
        state.connection.close()

    top_key = gatsby_data["candidates"][0]["key"]["key"] if gatsby_data["candidates"] else None
    print("\nReal-artifact resolve timings (Task 33, R79):")
    for label, seconds in timings.items():
        print(f"  {label}: {seconds:.2f} s")
    print(f"  case: {case.case_id}, labelled work_key: {case.label.work_key}")
    print(f"  Gatsby decision: verdict={gatsby_data['decision']['verdict']!r}, top key={top_key!r}")


@pytest.mark.artifact
def test_a_redirected_author_key_reaches_the_terminal_author_on_the_real_artifact(tmp_path):
    """R87: `work_authors` rows that name a merged-away author key must
    resolve through `redirects` to the terminal author. Measured on the
    2026-07-31 artifact: 53,835 work_authors rows point at an author key
    absent from `authors`, 53,792 of them resolvable author redirects
    (53,748 works, 46 terminal authors). "The Sea Wolf" (OL24569011W) names
    OL9258086A, which redirects to Jack London (OL44633A); before the fix
    its `authors` was `[]` and London's shelf missed 3,817 works (9,401
    where ~13.2k are expected). The shelf total and timings are printed
    (via -s) for the report."""
    root = os.environ.get("OL_DATA_ROOT")
    dump_date = os.environ.get("OL_DATA_VERSION")
    if not (root and dump_date):
        pytest.skip("set OL_DATA_ROOT and OL_DATA_VERSION")

    state = open_artifact(Settings(data_root=Path(root), data_version=dump_date, temp_dir=tmp_path))
    timings: dict[str, float] = {}
    try:
        with TestClient(create_app(state)) as client:
            start = time.perf_counter()
            response = client.get("/works/OL24569011W")
            timings["GET /works/OL24569011W"] = time.perf_counter() - start
            assert response.status_code == 200
            author_keys = [author["key"]["key"] for author in response.json()["data"]["authors"]]
            assert "OL44633A" in author_keys, (
                f"The Sea Wolf's author OL9258086A should resolve to OL44633A, got {author_keys}"
            )

            shelf_total = 0
            offset = 0
            start = time.perf_counter()
            while True:
                page_response = client.get(f"/authors/OL44633A/works?limit=500&offset={offset}")
                assert page_response.status_code == 200
                page = page_response.json()["data"]
                shelf_total += len(page)
                if len(page) < 500:
                    break
                offset += 500
            timings["GET /authors/OL44633A/works (all pages of 500)"] = time.perf_counter() - start
            assert shelf_total > 12_000, f"Jack London's shelf holds {shelf_total} works"
    finally:
        state.connection.close()

    print("\nReal-artifact author-redirect timings (R87):")
    for label, seconds in timings.items():
        print(f"  {label}: {seconds * 1000:.1f} ms")
    print(f"  OL44633A shelf total: {shelf_total} (was 9,401 before R87)")
