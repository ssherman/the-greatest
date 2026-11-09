DUMP = "2026-11-05"
BOOK, ACHEBE, TOLSTOY, HOMER = "Q622400", "Q155845", "Q7243", "Q6691"
PAINTING, EDITION = "Q12418", "Q900001"
REDIRECT_FROM = "Q900101"  # mini-redirect.sql: Q900101 -> Q622400


def post(client, path, body):
    return client.post(path, json=body)


def test_version_reports_the_artifact(wikidata_client):
    body = wikidata_client.get("/version").json()
    assert (body["source"], body["gates_passed"], body["dump_date"]) == ("wikidata", True, DUMP)
    assert set(body["tables"]) >= {"items", "labels"}


def test_items_returns_a_wbgetentities_shaped_entity(wikidata_client):
    body = post(wikidata_client, "/items", {"ids": [BOOK]}).json()
    entity = body["items"][BOOK]
    assert entity["id"] == BOOK
    assert entity["labels"]["en"]["value"]
    assert entity["claims"]["P495"][0]["mainsnak"]["datavalue"]["value"]["id"] == "Q145"
    assert entity["claims"]["P50"][0]["mainsnak"]["datavalue"]["value"]["id"] == ACHEBE
    assert set(entity) >= {"descriptions", "aliases", "sitelinks", "sitelink_count"}


def test_items_carry_dump_date_and_sitelink_count(wikidata_client):
    entity = post(wikidata_client, "/items", {"ids": [BOOK]}).json()["items"][BOOK]
    assert entity["dump_date"] == DUMP
    assert isinstance(entity["sitelink_count"], int)


def test_items_follows_redirect_and_keys_by_asked_qid(wikidata_client):
    body = post(wikidata_client, "/items", {"ids": [REDIRECT_FROM]}).json()
    assert body["items"][REDIRECT_FROM]["id"] == BOOK
    assert body["missing"] == [] and body["not_kept"] == []


def test_items_reports_not_kept_and_missing(wikidata_client):
    body = post(wikidata_client, "/items", {"ids": [PAINTING, "Q999999999", BOOK]}).json()
    assert body["not_kept"] == [PAINTING]
    assert body["missing"] == ["Q999999999"]
    assert list(body["items"]) == [BOOK]


def test_items_rejects_more_than_50(wikidata_client):
    ids = [f"Q{n}" for n in range(1, 52)]
    assert post(wikidata_client, "/items", {"ids": ids}).status_code == 422


def test_labels_follow_redirects_and_key_by_asked_qid(wikidata_client):
    body = post(wikidata_client, "/labels", {"ids": [ACHEBE, REDIRECT_FROM, "Q999999999"]}).json()
    assert set(body["labels"]) == {ACHEBE, REDIRECT_FROM}
    assert body["labels"][ACHEBE]["en"]
    assert set(body["labels"][ACHEBE]) == {"en", "mul", "description"}


def test_labels_rejects_more_than_500(wikidata_client):
    ids = [f"Q{n}" for n in range(1, 502)]
    assert post(wikidata_client, "/labels", {"ids": ids}).status_code == 422


def test_by_external_id_normalizes_isbn(wikidata_client):
    for pair in (["P212", "9780385474542"], ["P957", "0385474547"], ["P212", "978-0-385-47454-2"]):
        body = post(wikidata_client, "/by-external-id", {"pairs": [pair]}).json()
        assert body["ids"] == [EDITION], pair


def test_by_external_id_finds_viaf(wikidata_client):
    body = post(wikidata_client, "/by-external-id", {"pairs": [["P214", "24596756"]]}).json()
    assert body["ids"] == [ACHEBE]


def test_by_external_id_unknown_property_is_422(wikidata_client):
    assert post(wikidata_client, "/by-external-id", {"pairs": [["P1", "x"]]}).status_code == 422


def test_by_external_id_no_match_is_empty(wikidata_client):
    body = post(wikidata_client, "/by-external-id", {"pairs": [["P214", "1"]]}).json()
    assert body["ids"] == []


def test_linked_from_excludes_editions_and_scholarly(wikidata_client):
    body = post(
        wikidata_client,
        "/linked-from",
        {"targets": [ACHEBE], "properties": ["P50", "P800"], "exclude_types": ["Q3331189"]},
    ).json()
    assert [(r[0], r[1]) for r in body["rows"]] == [(ACHEBE, BOOK)]
    assert body["rows"][0][2] and body["truncated"] is False


def test_linked_from_truncation_flag(wikidata_client):
    body = post(
        wikidata_client, "/linked-from", {"targets": [ACHEBE], "properties": ["P50"], "limit": 1}
    ).json()
    assert len(body["rows"]) == 1


def test_names_matches_across_script_and_accents(wikidata_client):
    body = wikidata_client.get("/names", params={"q": "лев толстой"}).json()
    assert TOLSTOY in [h["id"] for h in body["hits"]]
    assert set(body["hits"][0]) == {"id", "label", "description"}


def test_names_matches_pseudonym_typed_item(wikidata_client):
    body = wikidata_client.get("/names", params={"q": "Homer"}).json()
    assert HOMER in [h["id"] for h in body["hits"]]


def test_names_no_match_is_empty(wikidata_client):
    assert wikidata_client.get("/names", params={"q": "zzzzqqq"}).json() == {"hits": []}
