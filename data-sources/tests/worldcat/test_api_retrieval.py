import pytest
from fastapi.testclient import TestClient

from worldcat.api.deps import Settings, open_artifact
from worldcat.api.main import create_app


@pytest.fixture(scope="module")
def client(worldcat_artifact, tmp_path_factory):
    state = open_artifact(
        Settings(
            data_root=worldcat_artifact.root,
            data_version=worldcat_artifact.dump_date,
            temp_dir=tmp_path_factory.mktemp("wc-tmp"),
        )
    )
    with TestClient(create_app(state)) as test_client:
        yield test_client


def test_an_isbn13_returns_its_records_with_holdings(client):
    body = client.get("/isbns/9780735211292").json()
    assert body["isbn13"] == "9780735211292"
    records = {r["oclc"]: r for r in body["records"]}
    atomic = records[1055766559]
    assert atomic["genre"] == "Nonfiction"
    assert "Habit" in atomic["subjects"]
    assert atomic["holdings"] == {"total_holding_count": 4000, "total_editions": 25}
    assert atomic["redirected_from"] is None
    assert "9781847941831" in atomic["isbn13s"]


def test_isbn10_with_x_and_hyphens_is_normalised(client):
    body = client.get("/isbns/0-395-47690-9").json()
    assert body["isbn13"] == "9780395476901"
    assert [r["oclc"] for r in body["records"]] == [1000415078]
    assert client.get("/isbns/080442957X").status_code == 200  # a valid X check digit is accepted


def test_an_unknown_isbn_is_an_empty_list_not_a_404(client):
    body = client.get("/isbns/9780306406157").json()  # synthetic brief-only record exists
    assert body["records"][0]["oclc"] == 9000000030
    body = client.get("/isbns/9783161484100").json()
    assert body == {"isbn13": "9783161484100", "records": []}


def test_a_bad_check_digit_or_garbage_is_422(client):
    assert client.get("/isbns/9780000000001").status_code == 422
    assert client.get("/isbns/not-an-isbn").status_code == 422


def test_oclc_lookup_follows_redirects_and_reports_the_source(client):
    direct = client.get("/oclc/1055766559").json()
    assert direct["redirected_from"] is None and direct["title"].startswith("Atomic")
    chained = client.get("/oclc/9000000010").json()
    assert chained["oclc"] == 1055766559 and chained["redirected_from"] == 9000000010
    assert client.get("/oclc/424242424242").status_code == 404
    assert client.get("/oclc/9000000020").status_code == 404  # a cycle resolves to nothing
    assert client.get("/oclc/abc").status_code == 422


def test_lookup_batch_keys_every_request_as_given(client):
    body = client.post(
        "/lookup", json={"isbn13s": ["9780735211292", "0-395-47690-9", "9783161484100"]}
    ).json()
    assert set(body["results"]) == {"9780735211292", "0-395-47690-9", "9783161484100"}
    assert body["results"]["0-395-47690-9"][0]["oclc"] == 1000415078
    assert body["results"]["9783161484100"] == []


def test_lookup_rejects_more_than_500_or_an_invalid_isbn(client):
    assert client.post("/lookup", json={"isbn13s": ["9780735211292"] * 501}).status_code == 422
    response = client.post("/lookup", json={"isbn13s": ["9780735211292", "garbage"]})
    assert response.status_code == 422
    assert "garbage" in response.json()["detail"]
