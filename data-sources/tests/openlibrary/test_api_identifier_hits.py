"""`_fetch_identifier_hits`: answered by key lookups, the same answer as the
single join it replaced.

The join read every row group of the identifier's type and probed the whole
`works` file per lookup; on the home server that pinned the VM during the
Goodreads replay. The fixture corpus files no identifier under a redirect
source key, so the redirect, dangling and cycle shapes are built here.
"""

from __future__ import annotations

import duckdb
import pytest

from openlibrary.api.retrieval import _fetch_identifier_hits
from openlibrary.pipeline.paths import ArtifactPaths

# The query `_fetch_identifier_hits` ran before the key-lookup rewrite.
REFERENCE = """
    WITH matched AS (
      SELECT i.edition_key, i.work_key AS requested_work,
             COALESCE(r.terminal_key, i.work_key) AS terminal
      FROM '{identifiers}' i
      LEFT JOIN '{redirects}' r
        ON r.source_key = i.work_key AND r.entity = 'work'
       AND NOT r.is_cycle AND NOT r.is_dangling
      WHERE i.id_type = ? AND i.value = ? AND i.work_key IS NOT NULL
    )
    SELECT m.terminal, m.requested_work, m.edition_key
    FROM matched m
    JOIN '{works}' w ON w.work_key = m.terminal
"""


def _reference(con, paths, id_type, value):
    rows = con.execute(
        REFERENCE.format(
            identifiers=paths.table("identifiers"),
            redirects=paths.table("redirects"),
            works=paths.table("works"),
        ),
        [id_type, value],
    ).fetchall()
    by_terminal: dict[str, tuple[set, set]] = {}
    for terminal, requested, edition in rows:
        redirected, editions = by_terminal.setdefault(terminal, (set(), set()))
        if requested != terminal:
            redirected.add(requested)
        if edition:
            editions.add(edition)
    return [
        (terminal, sorted(redirected), sorted(editions))
        for terminal, (redirected, editions) in sorted(by_terminal.items())
    ]


def _shape(hits):
    return [
        (hit.work.key, [k.key for k in hit.redirected_from], [k.key for k in hit.editions])
        for hit in hits
    ]


def test_every_fixture_identifier_gets_the_reference_answer(fixture_artifact):
    con = duckdb.connect()
    pairs = con.execute(
        f"SELECT DISTINCT id_type, value FROM '{fixture_artifact.table('identifiers')}' "
        "ORDER BY id_type, value"
    ).fetchall()
    assert len(pairs) > 50, "fixture corpus lost its identifiers"
    answered = 0
    for id_type, value in pairs:
        expected = _reference(con, fixture_artifact, id_type, value)
        answered += bool(expected)
        assert _shape(_fetch_identifier_hits(con, fixture_artifact, id_type, value)) == expected, (
            id_type,
            value,
        )
    assert answered > 50, "too few identifiers resolve to a work to compare anything"
    con.close()


@pytest.fixture()
def synthetic(tmp_path):
    """isbn13 9780000000001 is filed on six editions:
    E1 -> OLOLDW, which redirects to OLNEWW; E2 -> OLNEWW directly;
    E3 -> OLGONEW, in neither works nor redirects; E4 -> OLCYCW, a redirect
    cycle that is itself a work; E5 -> OLDANGW, a dangling redirect; E6 has no
    work. A second identifier, on E7 -> OLOTHERW, must not leak in."""
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.version_dir.mkdir(parents=True)
    con = duckdb.connect()
    con.execute(
        f"""
        COPY (SELECT * FROM (VALUES ('OLNEWW'), ('OLCYCW'), ('OLOTHERW')) t(work_key))
        TO '{paths.table("works")}' (FORMAT parquet)
        """
    )
    con.execute(
        f"""
        COPY (SELECT * FROM (VALUES
            ('work', 'OLOLDW', 'OLNEWW', 1::SMALLINT, false, false),
            ('work', 'OLCYCW', NULL, 2::SMALLINT, true, false),
            ('work', 'OLDANGW', 'OLMISSINGW', 1::SMALLINT, false, true),
            ('author', 'OLGONEW', 'OLNEWW', 1::SMALLINT, false, false)
          ) t(entity, source_key, terminal_key, depth, is_cycle, is_dangling))
        TO '{paths.table("redirects")}' (FORMAT parquet)
        """
    )
    con.execute(
        f"""
        COPY (SELECT * FROM (VALUES
            ('isbn13', '9780000000001', 'OL1M', 'OLOLDW', true),
            ('isbn13', '9780000000001', 'OL2M', 'OLNEWW', true),
            ('isbn13', '9780000000001', 'OL3M', 'OLGONEW', true),
            ('isbn13', '9780000000001', 'OL4M', 'OLCYCW', true),
            ('isbn13', '9780000000001', 'OL5M', 'OLDANGW', true),
            ('isbn13', '9780000000001', 'OL6M', NULL, true),
            ('isbn13', '9780000000002', 'OL7M', 'OLOTHERW', true)
          ) t(id_type, value, edition_key, work_key, checksum_ok))
        TO '{paths.table("identifiers")}' (FORMAT parquet)
        """
    )
    yield con, paths
    con.close()


def test_redirected_dangling_and_cyclic_work_keys(synthetic):
    con, paths = synthetic
    expected = [
        ("OLCYCW", [], ["OL4M"]),
        ("OLNEWW", ["OLOLDW"], ["OL1M", "OL2M"]),
    ]
    assert _reference(con, paths, "isbn13", "9780000000001") == expected
    assert _shape(_fetch_identifier_hits(con, paths, "isbn13", "9780000000001")) == expected


def test_an_unknown_value_has_no_hits(synthetic):
    con, paths = synthetic
    assert _fetch_identifier_hits(con, paths, "isbn13", "9789999999991") == []
