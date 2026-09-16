"""Task 34: the whole contract, end to end, against a built fixture artifact.

Two tests:

  * `test_the_whole_contract_in_one_walk_and_the_artifact_is_never_written` --
    boots the app with `TestClient` against a real (fixture-built) artifact
    and walks `/version`, a work, its editions, its author, that author's
    shelf, an identifier lookup, a batch, and a resolve, in one pass.
    Asserts every response carries `source_version` (`/version` carries the
    version fields at top level instead -- it has no envelope of its own,
    see `api/meta.py`) and that NOTHING under the version directory changes
    mtime or gains a new file over the whole walk. The mtime snapshot is
    taken before the first request, not after.
  * `test_every_route_is_read_only_except_the_three_named_post_routes` (R78)
    -- a route-TABLE test rather than a hand-picked endpoint list: it walks
    every route FastAPI actually registered and asserts every method set is
    a subset of {GET, POST, HEAD, OPTIONS} and that the routes allowing POST
    are exactly `/resolve`, `/works/batch`, `/authors/batch`. A PUT/PATCH/
    DELETE route added anywhere -- or a fourth POST route -- fails this
    without anyone remembering to update a checklist.

Both tests exercise code that already exists (Tasks 29-33): TDD's RED step
does not apply here the way it does for new production code. Written before
the Dockerfile/compose file per the task's own step order, both were
confirmed to pass on first run against the already-implemented app -- there
was no red phase to report.

Every discovery query below carries an ORDER BY and a predicate that pins
the shape the test needs (ruling R43), matching the discipline in
`test_api_retrieval.py` and `test_api_resolve.py`.
"""

from __future__ import annotations

import duckdb
import pytest
from fastapi.testclient import TestClient

from openlibrary.api.deps import Settings, open_artifact
from openlibrary.api.main import create_app

SOURCE = "openlibrary"


@pytest.fixture(scope="module")
def state(fixture_artifact):
    return open_artifact(
        Settings(data_root=fixture_artifact.root, data_version=fixture_artifact.dump_date)
    )


@pytest.fixture(scope="module")
def client(state):
    with TestClient(create_app(state)) as test_client:
        yield test_client


def _con():
    return duckdb.connect()


@pytest.fixture(scope="module")
def a_titled_work_with_an_author(fixture_artifact) -> tuple[str, str]:
    """(work_key, title) for a work carrying >=1 author, so "its first
    author" below is a real lookup rather than an empty list."""
    con = _con()
    row = con.execute(
        f"""
        SELECT w.work_key, w.title
        FROM '{fixture_artifact.table("works")}' w
        JOIN '{fixture_artifact.table("work_authors")}' wa USING (work_key)
        WHERE w.title IS NOT NULL AND w.title <> ''
        ORDER BY w.work_key LIMIT 1
        """
    ).fetchone()
    con.close()
    assert row is not None, "fixture corpus lost its titled, authored work"
    return row[0], row[1]


@pytest.fixture(scope="module")
def the_works_first_author(fixture_artifact, a_titled_work_with_an_author) -> str:
    work_key, _title = a_titled_work_with_an_author
    con = _con()
    row = con.execute(
        f"""
        SELECT author_key FROM '{fixture_artifact.table("work_authors")}'
        WHERE work_key = ? ORDER BY position LIMIT 1
        """,
        [work_key],
    ).fetchone()
    con.close()
    assert row is not None, "fixture corpus lost the discovered work's first author"
    return row[0]


@pytest.fixture(scope="module")
def an_isbn13_filed_against_a_real_work(fixture_artifact) -> str:
    """An isbn13 value whose `identifiers.work_key` is a REAL row in
    `works` -- an identifier filed only against a dangling work_key would
    make the identifier leg of the walk vacuous (200, empty list)."""
    con = _con()
    row = con.execute(
        f"""
        SELECT i.value
        FROM '{fixture_artifact.table("identifiers")}' i
        JOIN '{fixture_artifact.table("works")}' w ON w.work_key = i.work_key
        WHERE i.id_type = 'isbn13'
        ORDER BY i.value LIMIT 1
        """
    ).fetchone()
    con.close()
    assert row is not None, "fixture corpus lost an isbn13 filed against a real work"
    return row[0]


def _snapshot(version_dir):
    return {str(path): path.stat().st_mtime_ns for path in version_dir.rglob("*")}


def test_the_whole_contract_in_one_walk_and_the_artifact_is_never_written(
    client,
    fixture_artifact,
    a_titled_work_with_an_author,
    the_works_first_author,
    an_isbn13_filed_against_a_real_work,
):
    work_key, title = a_titled_work_with_an_author
    author_key = the_works_first_author
    isbn13_value = an_isbn13_filed_against_a_real_work

    # Snapshot BEFORE any request -- this is the whole point of the test.
    before = _snapshot(fixture_artifact.version_dir)

    def _get_envelope(path):
        response = client.get(path)
        assert response.status_code == 200, f"{path} -> {response.status_code}: {response.text}"
        body = response.json()
        assert body["source_version"]["source"] == SOURCE
        return body

    # /version: no envelope of its own -- the version fields are top level.
    version_response = client.get("/version")
    assert version_response.status_code == 200
    version_body = version_response.json()
    assert version_body["source"] == SOURCE
    assert version_body["dump_date"] == fixture_artifact.dump_date

    # A work.
    work_body = _get_envelope(f"/works/{work_key}")
    assert work_body["data"]["key"] == {"source": SOURCE, "key": work_key}

    # Its editions.
    editions_body = _get_envelope(f"/works/{work_key}/editions")
    assert isinstance(editions_body["data"], list)

    # Its first author.
    author_body = _get_envelope(f"/authors/{author_key}")
    assert author_body["data"]["key"] == {"source": SOURCE, "key": author_key}

    # That author's shelf.
    shelf_body = _get_envelope(f"/authors/{author_key}/works")
    assert isinstance(shelf_body["data"], list)

    # An identifier lookup.
    identifier_body = _get_envelope(f"/identifiers/isbn13/{isbn13_value}")
    assert identifier_body["data"], "identifier lookup returned no hits"
    assert identifier_body["data"][0]["id_type"] == "isbn13"

    # A batch.
    batch_response = client.post("/works/batch", json={"keys": [work_key]})
    assert batch_response.status_code == 200
    batch_body = batch_response.json()
    assert batch_body["source_version"]["source"] == SOURCE
    assert work_key in batch_body["data"]

    # A resolve.
    resolve_response = client.post("/resolve", json={"title": title})
    assert resolve_response.status_code == 200
    resolve_body = resolve_response.json()
    assert resolve_body["source_version"]["source"] == SOURCE
    assert isinstance(resolve_body["data"]["candidates"], list)

    after = _snapshot(fixture_artifact.version_dir)
    assert set(after) == set(before), (
        "a file appeared or disappeared under the version directory during the walk"
    )
    assert after == before, "a file's mtime changed under the version directory during the walk"


# ------------------------------------------------------------------ route table


_ALLOWED_METHODS = {"GET", "POST", "HEAD", "OPTIONS"}
_BUILTIN_DOC_PATHS = {"/openapi.json", "/docs", "/docs/oauth2-redirect", "/redoc"}
_EXPECTED_POST_PATHS = {"/resolve", "/works/batch", "/authors/batch"}


def _flatten_routes(routes):
    """Recurse through FastAPI's lazy `_IncludedRouter` wrappers -- routes
    registered via `app.include_router` do not appear directly in
    `app.routes` on this FastAPI version, only a wrapper carrying
    `original_router` -- down to the real `Route`/`APIRoute` objects."""
    flattened = []
    for route in routes:
        original_router = getattr(route, "original_router", None)
        if original_router is not None:
            flattened.extend(_flatten_routes(original_router.routes))
        else:
            flattened.append(route)
    return flattened


def test_every_route_is_read_only_except_the_three_named_post_routes(client):
    """R78: iterates the app's actual route table (skipping FastAPI's own
    docs/openapi routes) instead of a hand-picked endpoint list, so a
    PUT/PATCH/DELETE route -- or a fourth POST route -- added anywhere fails
    this without anyone remembering to update a checklist."""
    post_paths = set()
    for route in _flatten_routes(client.app.routes):
        path = getattr(route, "path", None)
        methods = getattr(route, "methods", None)
        if path is None or methods is None or path in _BUILTIN_DOC_PATHS:
            continue
        disallowed = methods - _ALLOWED_METHODS
        assert not disallowed, f"{path} allows disallowed method(s): {disallowed}"
        if "POST" in methods:
            post_paths.add(path)
    assert post_paths == _EXPECTED_POST_PATHS
