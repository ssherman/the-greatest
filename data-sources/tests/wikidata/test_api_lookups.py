DUMP = "2026-11-05"
BOOK, ACHEBE, TOLSTOY, HOMER = "Q622400", "Q155845", "Q7243", "Q6691"
PAINTING, EDITION = "Q12418", "Q900001"
ESSAYIST, RANKED, UNKEPT_REDIRECT = "Q900020", "Q900021", "Q900106"
REDIRECT_FROM = "Q900101"  # mini-redirect.sql: Q900101 -> Q622400


def post(client, path, body):
    return client.post(path, json=body)


def test_version_reports_the_artifact(wikidata_client):
    body = wikidata_client.get("/version").json()
    assert (body["source"], body["gates_passed"], body["dump_date"]) == ("wikidata", True, DUMP)
    assert set(body["tables"]) >= {"items", "labels"}
    assert body["redirects_dump_date"] == "2026-11-01"


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
    def run(limit):
        return post(
            wikidata_client,
            "/linked-from",
            {"targets": [ACHEBE, RANKED], "properties": ["P50", "P800"], "limit": limit},
        ).json()

    assert (len(run(1)["rows"]), run(1)["truncated"]) == (1, True)
    assert (len(run(2)["rows"]), run(2)["truncated"]) == (2, False)


def test_linked_from_multi_target_reverse_rows_then_p800_rows(wikidata_client):
    body = post(
        wikidata_client,
        "/linked-from",
        {"targets": [ESSAYIST, ACHEBE], "properties": ["P50", "P800"]},
    ).json()
    assert [(r[0], r[1]) for r in body["rows"]] == [(ACHEBE, BOOK), (ESSAYIST, BOOK)]
    assert body["truncated"] is False


def test_linked_from_pages_through_links_when_a_batch_is_filtered_away(
    wikidata_client, monkeypatch
):
    from wikidata.api import lookups

    # One link per batch: a batch whose only source is excluded must not end the search.
    monkeypatch.setattr(lookups, "LINK_BATCH", 1)
    body = post(
        wikidata_client,
        "/linked-from",
        {"targets": [ACHEBE], "properties": ["P50"], "exclude_types": ["Q3331189"]},
    ).json()
    assert [(r[0], r[1]) for r in body["rows"]] == [(ACHEBE, BOOK)]


def test_linked_from_p50_uses_best_rank_only(wikidata_client):
    outranked = post(wikidata_client, "/linked-from", {"targets": [ACHEBE], "properties": ["P50"]})
    assert "Q900023" not in [r[1] for r in outranked.json()["rows"]]
    best = post(wikidata_client, "/linked-from", {"targets": ["Q900006"], "properties": ["P50"]})
    assert "Q900023" in [r[1] for r in best.json()["rows"]]


def test_linked_from_p800_flags_truncation_at_the_works_cap(wikidata_client, monkeypatch):
    from wikidata.api import lookups

    monkeypatch.setattr(lookups, "P800_WORK_CAP", 0)
    body = post(wikidata_client, "/linked-from", {"targets": [ESSAYIST], "properties": ["P800"]})
    assert body.json() == {"rows": [], "truncated": True}


def test_linked_from_p800_drops_unkept_sources_and_deprecated_statements(wikidata_client):
    body = post(wikidata_client, "/linked-from", {"targets": [ESSAYIST], "properties": ["P800"]})
    # Q900002 (scholarly article) is not in items; Q12418 is deprecated and unkept.
    assert [(r[0], r[1]) for r in body.json()["rows"]] == [(ESSAYIST, BOOK)]


def test_linked_from_p800_uses_best_rank_only(wikidata_client):
    body = post(wikidata_client, "/linked-from", {"targets": [RANKED], "properties": ["P800"]})
    assert [r[1] for r in body.json()["rows"]] == [BOOK]  # the normal Q900005 is outranked


def test_linked_from_p800_still_applies_exclude_types(wikidata_client):
    body = post(
        wikidata_client,
        "/linked-from",
        {"targets": [ESSAYIST], "properties": ["P800"], "exclude_types": ["Q7725634"]},
    )
    assert body.json()["rows"] == []


def test_malformed_ids_are_422_not_missing(wikidata_client):
    assert post(wikidata_client, "/items", {"ids": ["Q0"]}).status_code == 422
    assert post(wikidata_client, "/labels", {"ids": ["x'; --"]}).status_code == 422
    assert post(wikidata_client, "/linked-from", {"targets": ["Q01"]}).status_code == 422


def test_a_redirect_to_an_unkept_entity_is_not_kept_never_missing(wikidata_client):
    body = post(wikidata_client, "/items", {"ids": [UNKEPT_REDIRECT]}).json()
    assert (body["not_kept"], body["missing"], body["items"]) == ([UNKEPT_REDIRECT], [], {})


def test_isbn10_only_item_is_found_via_either_property(wikidata_client):
    for pair in (["P957", "0306406152"], ["P212", "9780306406157"]):
        body = post(wikidata_client, "/by-external-id", {"pairs": [pair]}).json()
        assert body["ids"] == ["Q900022"], pair


def test_names_matches_across_script_and_accents(wikidata_client):
    body = wikidata_client.get("/names", params={"q": "лев толстой"}).json()
    assert TOLSTOY in [h["id"] for h in body["hits"]]
    assert set(body["hits"][0]) == {"id", "label", "description"}


def test_names_matches_pseudonym_typed_item(wikidata_client):
    body = wikidata_client.get("/names", params={"q": "Homer"}).json()
    assert HOMER in [h["id"] for h in body["hits"]]


def test_names_no_match_is_empty(wikidata_client):
    assert wikidata_client.get("/names", params={"q": "zzzzqqq"}).json() == {"hits": []}


def test_names_retries_without_a_middle_initial(wikidata_client):
    plain = wikidata_client.get("/names", params={"q": "Chinua Achebe"}).json()["hits"]
    assert ACHEBE in [h["id"] for h in plain]
    body = wikidata_client.get("/names", params={"q": "Chinua O. Achebe"}).json()
    assert [h["id"] for h in body["hits"]] == [h["id"] for h in plain]


def test_names_initial_retry_needs_two_remaining_tokens(wikidata_client):
    assert wikidata_client.get("/names", params={"q": "Homer X."}).json()["hits"] == []
