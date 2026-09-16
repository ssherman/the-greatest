"""GET /works, /works/.../editions, /authors, /authors/.../works, /identifiers.

Every discovery query below carries an ORDER BY and a predicate that pins the
shape the test needs (ruling R43 -- a flaky discovery query cost this project
a day). Three shapes the plan calls out as possibly missing from the fixture
corpus (a stale-key edition, an identifier filed under a redirect source, and
a resolvable author redirect whose source appears in `work_authors` -- R87)
were checked directly against the built fixture artifact and confirmed absent,
so those tests keep a documented `pytest.skip` fallback (the R87 shape is
covered deterministically in `test_api_author_redirects.py` and against the
real artifact in `test_api_artifact.py`); every other shape here is confirmed
present and asserted on directly.
"""

from __future__ import annotations

import duckdb
import pytest
from fastapi.testclient import TestClient

from openlibrary.api.deps import Settings, open_artifact
from openlibrary.api.main import create_app


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
def a_richly_described_work_key(fixture_artifact) -> str:
    """A work with a title, >=1 author, >=1 subject and a year_evidence row --
    so the "carries title/authors/subjects/year_evidence" test cannot pass
    vacuously against an all-empty record."""
    con = _con()
    row = con.execute(
        f"""
        SELECT w.work_key FROM '{fixture_artifact.table("works")}' w
        JOIN '{fixture_artifact.table("work_authors")}' wa USING (work_key)
        JOIN '{fixture_artifact.table("work_details")}' d USING (work_key)
        JOIN '{fixture_artifact.table("year_evidence")}' y USING (work_key)
        WHERE d.subjects IS NOT NULL AND len(d.subjects) > 0
        ORDER BY w.work_key LIMIT 1
        """
    ).fetchone()
    con.close()
    assert row is not None, "fixture corpus lost its richly-described work"
    return row[0]


@pytest.fixture(scope="module")
def a_work_with_two_authors(fixture_artifact) -> tuple[str, list[str]]:
    """A work with >=2 work_authors rows, so author ORDER BY position is a
    real assertion rather than a single-element list."""
    con = _con()
    work_key = con.execute(
        f"""
        SELECT work_key FROM '{fixture_artifact.table("work_authors")}'
        GROUP BY work_key HAVING count(*) >= 2
        ORDER BY work_key LIMIT 1
        """
    ).fetchone()
    assert work_key is not None, "fixture corpus lost its multi-author work"
    (work_key,) = work_key
    author_keys = [
        row[0]
        for row in con.execute(
            f"""
            SELECT author_key FROM '{fixture_artifact.table("work_authors")}'
            WHERE work_key = ? ORDER BY position
            """,
            [work_key],
        ).fetchall()
    ]
    con.close()
    return work_key, author_keys


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
def a_work_with_multiple_editions(fixture_artifact) -> str:
    con = _con()
    row = con.execute(
        f"""
        SELECT work_key FROM '{fixture_artifact.table("editions")}'
        WHERE work_key IS NOT NULL
        GROUP BY work_key HAVING count(*) >= 2
        ORDER BY work_key LIMIT 1
        """
    ).fetchone()
    con.close()
    assert row is not None, "fixture corpus lost its multi-edition work"
    return row[0]


@pytest.fixture(scope="module")
def an_edition_with_two_isbn13s(fixture_artifact) -> tuple[str, str, list[str]]:
    """(work_key, edition_key, sorted isbn13 values) for an edition carrying
    2+ distinct isbn13 values -- proof the isbn13 list is deduplicated and
    sorted, not merely present."""
    con = _con()
    row = con.execute(
        f"""
        SELECT e.work_key, e.edition_key
        FROM '{fixture_artifact.table("identifiers")}' i
        JOIN '{fixture_artifact.table("editions")}' e USING (edition_key)
        WHERE i.id_type = 'isbn13' AND e.work_key IS NOT NULL
        GROUP BY e.work_key, e.edition_key
        HAVING count(DISTINCT i.value) >= 2
        ORDER BY e.work_key, e.edition_key LIMIT 1
        """
    ).fetchone()
    assert row is not None, "fixture corpus lost its multi-isbn13 edition"
    work_key, edition_key = row
    values = sorted(
        v
        for (v,) in con.execute(
            f"""
            SELECT DISTINCT value FROM '{fixture_artifact.table("identifiers")}'
            WHERE id_type = 'isbn13' AND edition_key = ?
            """,
            [edition_key],
        ).fetchall()
    )
    con.close()
    return work_key, edition_key, values


@pytest.fixture(scope="module")
def author_with_the_biggest_shelf(fixture_artifact) -> str:
    con = _con()
    (author_key,) = con.execute(
        f"""
        SELECT author_key FROM '{fixture_artifact.table("work_authors")}'
        GROUP BY author_key ORDER BY count(*) DESC, author_key LIMIT 1
        """
    ).fetchone()
    con.close()
    return author_key


@pytest.fixture(scope="module")
def an_author_with_alternate_names(fixture_artifact) -> str:
    con = _con()
    row = con.execute(
        f"""
        SELECT author_key FROM '{fixture_artifact.table("author_names")}'
        WHERE source = 'alternate'
        GROUP BY author_key ORDER BY author_key LIMIT 1
        """
    ).fetchone()
    con.close()
    assert row is not None, "fixture corpus lost its alternate-named author"
    return row[0]


@pytest.fixture(scope="module")
def a_reused_isbn13(fixture_artifact) -> tuple[str, list[str]]:
    """(value, sorted terminal work keys) for an isbn13 shared by >1 REAL work.

    `identifiers.work_key` can reference a work_key that is neither present
    in `works` nor tracked in `redirects` -- a plain dangling reference the
    endpoint correctly drops (R83) -- so this must join `works` too, not just
    group by `identifiers.work_key`.
    """
    con = _con()
    row = con.execute(
        f"""
        SELECT i.value FROM '{fixture_artifact.table("identifiers")}' i
        JOIN '{fixture_artifact.table("works")}' w ON w.work_key = i.work_key
        WHERE i.id_type = 'isbn13'
        GROUP BY i.value HAVING count(DISTINCT i.work_key) > 1
        ORDER BY i.value LIMIT 1
        """
    ).fetchone()
    assert row is not None, "fixture corpus lost its reused isbn13"
    (value,) = row
    work_keys = sorted(
        k
        for (k,) in con.execute(
            f"""
            SELECT DISTINCT i.work_key FROM '{fixture_artifact.table("identifiers")}' i
            JOIN '{fixture_artifact.table("works")}' w ON w.work_key = i.work_key
            WHERE i.id_type = 'isbn13' AND i.value = ?
            """,
            [value],
        ).fetchall()
    )
    con.close()
    return value, work_keys


@pytest.fixture(scope="module")
def a_single_work_isbn13(fixture_artifact) -> tuple[str, str]:
    """(value, work_key) for an isbn13 belonging to exactly one REAL work
    (see `a_reused_isbn13` for why the join against `works` matters)."""
    con = _con()
    row = con.execute(
        f"""
        SELECT i.value FROM '{fixture_artifact.table("identifiers")}' i
        JOIN '{fixture_artifact.table("works")}' w ON w.work_key = i.work_key
        WHERE i.id_type = 'isbn13'
        GROUP BY i.value HAVING count(DISTINCT i.work_key) = 1
        ORDER BY i.value LIMIT 1
        """
    ).fetchone()
    assert row is not None, "fixture corpus lost its single-work isbn13"
    (value,) = row
    (work_key,) = con.execute(
        f"""
        SELECT DISTINCT i.work_key FROM '{fixture_artifact.table("identifiers")}' i
        JOIN '{fixture_artifact.table("works")}' w ON w.work_key = i.work_key
        WHERE i.id_type = 'isbn13' AND i.value = ?
        """,
        [value],
    ).fetchone()
    con.close()
    return value, work_key


# ---------------------------------------------------------------- /works/{key}


def test_a_work_is_returned_with_its_source_version(client, a_richly_described_work_key):
    body = client.get(f"/works/{a_richly_described_work_key}").json()
    assert body["source_version"]["dump_date"] == "2026-07-31"
    assert body["data"]["key"] == {"source": "openlibrary", "key": a_richly_described_work_key}


def test_a_work_record_carries_title_authors_subjects_and_year_evidence(
    client, a_richly_described_work_key
):
    data = client.get(f"/works/{a_richly_described_work_key}").json()["data"]
    assert data["title"]
    assert len(data["authors"]) >= 1
    assert len(data["subjects"]) >= 1
    # Year EVIDENCE, not a year: nothing in the pipeline asserts one.
    assert data["year_evidence"] is not None
    assert "first_publish_year" not in data
    assert "declared_year" in data["year_evidence"]


def test_a_works_authors_are_ordered_by_position(client, a_work_with_two_authors):
    work_key, expected_author_keys = a_work_with_two_authors
    data = client.get(f"/works/{work_key}").json()["data"]
    assert [a["key"]["key"] for a in data["authors"]] == expected_author_keys


def test_an_unknown_work_is_a_404(client):
    response = client.get("/works/OL999999999W")
    assert response.status_code == 404
    assert "OL999999999W" in response.json()["detail"]


def test_a_redirected_key_returns_the_terminal_record_and_says_where_it_came_from(
    client, a_resolvable_work_redirect
):
    source_key, terminal_key = a_resolvable_work_redirect
    body = client.get(f"/works/{source_key}").json()
    assert body["data"]["key"]["key"] == terminal_key
    assert body["data"]["redirected_from"] == [{"source": "openlibrary", "key": source_key}]


def test_the_terminal_key_itself_carries_no_redirected_from(client, a_resolvable_work_redirect):
    _, terminal_key = a_resolvable_work_redirect
    body = client.get(f"/works/{terminal_key}").json()
    assert body["data"]["redirected_from"] == []


def test_a_malformed_work_key_is_a_422(client):
    assert client.get("/works/not-a-key").status_code == 422


@pytest.fixture(scope="module")
def a_work_filed_under_a_redirected_author(fixture_artifact):
    """(work_key, source_author_key, terminal_author_key) for a `work_authors`
    row whose author key is a resolvable author redirect (R87). Measured
    against the fixture corpus: all 68 of its author redirects are dangling,
    so this is None today and the two tests below skip -- see
    `test_api_author_redirects.py` for the deterministic coverage."""
    con = _con()
    row = con.execute(
        f"""
        SELECT wa.work_key, r.source_key, r.terminal_key
        FROM '{fixture_artifact.table("redirects")}' r
        JOIN '{fixture_artifact.table("work_authors")}' wa ON wa.author_key = r.source_key
        WHERE r.entity = 'author' AND NOT r.is_cycle AND NOT r.is_dangling
        ORDER BY r.source_key, wa.work_key LIMIT 1
        """
    ).fetchone()
    con.close()
    return row


def test_a_works_redirected_author_key_resolves_to_the_terminal_author(
    client, a_work_filed_under_a_redirected_author
):
    """R87: `authors` on a work record carries the TERMINAL author key, never
    the merged-away one."""
    if a_work_filed_under_a_redirected_author is None:
        pytest.skip("fixture corpus has no work filed under a resolvable author redirect")
    work_key, source_key, terminal_key = a_work_filed_under_a_redirected_author
    data = client.get(f"/works/{work_key}").json()["data"]
    author_keys = [a["key"]["key"] for a in data["authors"]]
    assert terminal_key in author_keys
    assert source_key not in author_keys


# ---------------------------------------------------------- /works/{key}/editions


def test_editions_for_a_work_carry_the_bibliographic_fields(client, a_work_with_multiple_editions):
    editions = client.get(f"/works/{a_work_with_multiple_editions}/editions").json()["data"]
    assert len(editions) >= 2
    first = editions[0]
    for field in (
        "language_code",
        "page_count",
        "publisher",
        "publish_year",
        "physical_format",
        "isbn13",
    ):
        assert field in first


def test_editions_are_ordered_by_publish_year_then_key(client, a_work_with_multiple_editions):
    editions = client.get(f"/works/{a_work_with_multiple_editions}/editions").json()["data"]
    years = [e["publish_year"] for e in editions]
    present_years = [y for y in years if y is not None]
    assert present_years == sorted(present_years)
    # Nulls sort last.
    assert years == sorted(years, key=lambda y: (y is None, y))


def test_an_editions_isbn13_list_is_sorted_and_deduplicated(client, an_edition_with_two_isbn13s):
    work_key, edition_key, expected_isbn13s = an_edition_with_two_isbn13s
    editions = client.get(f"/works/{work_key}/editions").json()["data"]
    match = next(e for e in editions if e["key"]["key"] == edition_key)
    assert match["isbn13"] == expected_isbn13s


def test_editions_reach_through_a_stale_work_key(client, fixture_artifact):
    """R83: editions filed under a merged-away key must still surface under
    the terminal. The fixture corpus's one resolvable redirect
    (OL15331408W -> OL3809593W) was measured to carry no editions under the
    stale source key, so this genuinely has no fixture to assert against."""
    con = _con()
    row = con.execute(
        f"""
        SELECT e.work_key FROM '{fixture_artifact.table("editions")}' e
        JOIN '{fixture_artifact.table("redirects")}' r ON r.source_key = e.work_key
        WHERE r.entity = 'work' AND NOT r.is_cycle AND NOT r.is_dangling
        ORDER BY e.work_key LIMIT 1
        """
    ).fetchone()
    con.close()
    if row is None:
        pytest.skip("fixture corpus has no edition filed under a redirect source key")
    (stale_key,) = row
    editions = client.get(f"/works/{stale_key}/editions").json()["data"]
    assert editions


def test_editions_for_an_unknown_work_is_a_404(client):
    assert client.get("/works/OL999999999W/editions").status_code == 404


# --------------------------------------------------------------- /authors/{key}


def test_an_author_and_their_shelf_are_returned(client, author_with_the_biggest_shelf):
    assert client.get(f"/authors/{author_with_the_biggest_shelf}").status_code == 200
    shelf = client.get(f"/authors/{author_with_the_biggest_shelf}/works").json()["data"]
    assert isinstance(shelf, list)
    assert shelf


def test_an_authors_alternate_names_are_included(client, an_author_with_alternate_names):
    data = client.get(f"/authors/{an_author_with_alternate_names}").json()["data"]
    assert data["alternate_names"]


def test_an_unknown_author_is_a_404(client):
    assert client.get("/authors/OL999999999A").status_code == 404


def test_a_malformed_author_key_is_a_422(client):
    assert client.get("/authors/not-a-key").status_code == 422


# -------------------------------------------------------------- /authors/{key}/works


def test_the_shelf_is_paginated_and_popularity_ordered(client, author_with_the_biggest_shelf):
    page = client.get(f"/authors/{author_with_the_biggest_shelf}/works?limit=1").json()["data"]
    assert len(page) <= 1
    full = client.get(f"/authors/{author_with_the_biggest_shelf}/works?limit=500").json()["data"]
    signals = [w["readinglog_count"] for w in full]
    assert signals == sorted(signals, reverse=True)


def test_shelf_offset_returns_the_next_slice(client, author_with_the_biggest_shelf):
    full = client.get(f"/authors/{author_with_the_biggest_shelf}/works?limit=500").json()["data"]
    assert len(full) >= 10, "fixture author's shelf shrank below what this test needs"
    first_five = client.get(
        f"/authors/{author_with_the_biggest_shelf}/works?limit=5&offset=0"
    ).json()["data"]
    next_five = client.get(
        f"/authors/{author_with_the_biggest_shelf}/works?limit=5&offset=5"
    ).json()["data"]
    assert [w["key"]["key"] for w in first_five] == [w["key"]["key"] for w in full[:5]]
    assert [w["key"]["key"] for w in next_five] == [w["key"]["key"] for w in full[5:10]]


def test_shelf_limit_out_of_range_is_a_422(client, author_with_the_biggest_shelf):
    assert client.get(f"/authors/{author_with_the_biggest_shelf}/works?limit=0").status_code == 422
    assert (
        client.get(f"/authors/{author_with_the_biggest_shelf}/works?limit=501").status_code == 422
    )


def test_shelf_negative_offset_is_a_422(client, author_with_the_biggest_shelf):
    assert (
        client.get(f"/authors/{author_with_the_biggest_shelf}/works?offset=-1").status_code == 422
    )


def test_the_shelf_reaches_works_filed_under_a_redirected_author_key(
    client, a_work_filed_under_a_redirected_author
):
    """R87: the mirror of `test_editions_reach_through_a_stale_work_key` for
    authors -- a work filed under a merged-away author key sits on the
    terminal author's shelf."""
    if a_work_filed_under_a_redirected_author is None:
        pytest.skip("fixture corpus has no work filed under a resolvable author redirect")
    work_key, _source_key, terminal_key = a_work_filed_under_a_redirected_author
    shelf = client.get(f"/authors/{terminal_key}/works?limit=500").json()["data"]
    assert work_key in [entry["key"]["key"] for entry in shelf]


# ------------------------------------------------------------- /identifiers/{type}/{value}


def test_an_identifier_lookup_always_returns_a_list(client, a_single_work_isbn13):
    value, work_key = a_single_work_isbn13
    data = client.get(f"/identifiers/isbn13/{value}").json()["data"]
    assert isinstance(data, list)
    assert [hit["work"]["key"] for hit in data] == [work_key]
    assert data[0]["id_type"] == "isbn13"
    assert data[0]["value"] == value
    assert data[0]["redirected_from"] == []


def test_a_reused_isbn_returns_one_hit_per_work(client, a_reused_isbn13):
    value, expected_work_keys = a_reused_isbn13
    data = client.get(f"/identifiers/isbn13/{value}").json()["data"]
    # ISBNs are reused. The caller sees the ambiguity rather than a guess.
    assert [hit["work"]["key"] for hit in data] == expected_work_keys


def test_an_unknown_identifier_returns_an_empty_list_not_a_404(client):
    response = client.get("/identifiers/isbn13/9999999999999")
    assert response.status_code == 200
    assert response.json()["data"] == []


def test_an_unknown_identifier_type_is_a_422(client):
    assert client.get("/identifiers/made_up/123").status_code == 422


def test_an_identifier_value_the_normalizer_rejects_is_a_422(client):
    # Not 10 alphanumeric characters -- normalize_asin returns None.
    assert client.get("/identifiers/asin/nope").status_code == 422


def test_a_redirected_identifiers_work_key_resolves_to_the_terminal(client, fixture_artifact):
    """R83: an identifier filed against a work_key that has since been merged
    away must surface under the terminal, with the stale key in
    redirected_from. Measured against the fixture corpus: no identifier row
    is filed under a redirect source key, so this genuinely has no fixture
    to assert against."""
    con = _con()
    row = con.execute(
        f"""
        SELECT i.id_type, i.value FROM '{fixture_artifact.table("identifiers")}' i
        JOIN '{fixture_artifact.table("redirects")}' r
          ON r.source_key = i.work_key AND r.entity = 'work' AND NOT r.is_cycle
             AND NOT r.is_dangling
        WHERE i.work_key IS NOT NULL
        ORDER BY i.id_type, i.value LIMIT 1
        """
    ).fetchone()
    con.close()
    if row is None:
        pytest.skip("fixture corpus has no identifier filed under a redirect source key")
    id_type, value = row
    data = client.get(f"/identifiers/{id_type}/{value}").json()["data"]
    assert data
    assert data[0]["redirected_from"]
