"""POST /works/batch, POST /authors/batch.

Thin wrappers over the set-based `fetch_works`/`fetch_authors` (ruling R71 in
retrieval.py) -- one query per batch, keyed by the REQUESTED key so a caller
can match responses to requests even when a redirect changed the key.

Every discovery query below carries an ORDER BY and a predicate that pins the
shape the test needs (ruling R43). The fixture corpus is known to hold exactly
one resolvable work redirect (OL15331408W -> OL3809593W, per
test_api_retrieval.py), so the redirect-keyed test asserts directly instead of
skipping.
"""

from __future__ import annotations

import duckdb
import pytest
from fastapi.testclient import TestClient

from openlibrary.api.deps import Settings, open_artifact
from openlibrary.api.main import create_app
from openlibrary.api.retrieval import MAX_BATCH


@pytest.fixture(scope="module")
def client(fixture_artifact):
    state = open_artifact(
        Settings(data_root=fixture_artifact.root, data_version=fixture_artifact.dump_date)
    )
    with TestClient(create_app(state)) as test_client:
        yield test_client


def _con():
    return duckdb.connect()


@pytest.fixture(scope="module")
def a_resolvable_work_redirect(fixture_artifact) -> tuple[str, str]:
    """(source_key, terminal_key) for a non-cycle, non-dangling work redirect.
    Known to exist: OL15331408W -> OL3809593W."""
    con = _con()
    row = con.execute(
        f"""
        SELECT source_key, terminal_key FROM '{fixture_artifact.table("redirects")}'
        WHERE entity = 'work' AND NOT is_cycle AND NOT is_dangling
        ORDER BY source_key LIMIT 1
        """
    ).fetchone()
    con.close()
    assert row is not None, "fixture corpus lost its resolvable work redirect"
    return row[0], row[1]


@pytest.fixture(scope="module")
def a_known_work_key(fixture_artifact) -> str:
    con = _con()
    row = con.execute(
        f"SELECT work_key FROM '{fixture_artifact.table('works')}' ORDER BY work_key LIMIT 1"
    ).fetchone()
    con.close()
    assert row is not None, "fixture corpus lost its works table contents"
    return row[0]


# --------------------------------------------------------------- /works/batch


def test_a_batch_returns_one_entry_per_requested_key(client, fixture_artifact):
    con = _con()
    keys = [
        r[0]
        for r in con.execute(
            f"SELECT work_key FROM '{fixture_artifact.table('works')}' ORDER BY work_key LIMIT 3"
        ).fetchall()
    ]
    con.close()
    data = client.post("/works/batch", json={"keys": keys}).json()["data"]
    assert set(data) == set(keys)


def test_a_batch_keys_its_response_by_the_requested_key_not_the_terminal_one(
    client, a_resolvable_work_redirect
):
    source_key, terminal_key = a_resolvable_work_redirect
    data = client.post("/works/batch", json={"keys": [source_key]}).json()["data"]
    # Keyed by what was asked for, so a caller can match responses to requests.
    assert source_key in data
    assert data[source_key]["key"]["key"] == terminal_key
    assert data[source_key]["redirected_from"] == [{"source": "openlibrary", "key": source_key}]


def test_an_unknown_key_in_a_batch_is_null_not_an_error(client):
    data = client.post("/works/batch", json={"keys": ["OL999999999W"]}).json()["data"]
    assert data["OL999999999W"] is None


def test_an_empty_batch_is_accepted(client):
    assert client.post("/works/batch", json={"keys": []}).json()["data"] == {}


def test_a_batch_over_the_cap_is_rejected(client):
    response = client.post("/works/batch", json={"keys": [f"OL{i}W" for i in range(MAX_BATCH + 1)]})
    assert response.status_code == 422


def test_duplicate_keys_in_a_batch_are_deduplicated(client, a_known_work_key):
    data = client.post("/works/batch", json={"keys": [a_known_work_key, a_known_work_key]}).json()[
        "data"
    ]
    assert list(data) == [a_known_work_key]


def test_a_malformed_key_in_a_works_batch_is_a_422_naming_it(client, a_known_work_key):
    response = client.post("/works/batch", json={"keys": [a_known_work_key, "not-a-key"]})
    assert response.status_code == 422
    assert "not-a-key" in response.text


def test_a_batch_mixing_known_redirected_and_unknown_keys(
    client, a_known_work_key, a_resolvable_work_redirect
):
    source_key, terminal_key = a_resolvable_work_redirect
    unknown_key = "OL999999999W"
    data = client.post(
        "/works/batch", json={"keys": [a_known_work_key, source_key, unknown_key]}
    ).json()["data"]
    assert set(data) == {a_known_work_key, source_key, unknown_key}
    assert data[a_known_work_key]["key"]["key"] == a_known_work_key
    assert data[source_key]["key"]["key"] == terminal_key
    assert data[source_key]["redirected_from"] == [{"source": "openlibrary", "key": source_key}]
    assert data[unknown_key] is None


# ------------------------------------------------------------- /authors/batch


def test_an_author_batch_works_the_same_way(client, fixture_artifact):
    con = _con()
    keys = [
        r[0]
        for r in con.execute(
            f"""
            SELECT author_key FROM '{fixture_artifact.table("authors")}'
            ORDER BY author_key LIMIT 2
            """
        ).fetchall()
    ]
    con.close()
    data = client.post("/authors/batch", json={"keys": keys}).json()["data"]
    assert set(data) == set(keys)


def test_a_malformed_key_in_an_authors_batch_is_a_422_naming_it(client):
    response = client.post("/authors/batch", json={"keys": ["not-a-key"]})
    assert response.status_code == 422
    assert "not-a-key" in response.text


def test_an_authors_batch_over_the_cap_is_rejected(client):
    response = client.post(
        "/authors/batch", json={"keys": [f"OL{i}A" for i in range(MAX_BATCH + 1)]}
    )
    assert response.status_code == 422
