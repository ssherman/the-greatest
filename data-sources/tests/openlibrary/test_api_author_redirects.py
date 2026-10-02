"""R87: `work_authors` rows naming a merged-away author key reach the terminal.

The committed fixture corpus carries 68 author redirects and every one of
them is dangling (checked directly against the built fixture artifact:
`SELECT ... FROM redirects r JOIN work_authors wa ON wa.author_key =
r.source_key WHERE r.entity = 'author' AND NOT r.is_cycle AND NOT
r.is_dangling` returns nothing), so the fixture-backed tests in
`test_api_retrieval.py` skip. The real-artifact case lives in
`test_api_artifact.py`. This module gives the two fetchers a deterministic
RED/GREEN without the real artifact: a hand-built version directory of
Parquet tables -- only the columns `fetch_works` and `_fetch_shelf` read --
with one resolvable author redirect (OL9A -> OL1A), one cycle and one
dangling redirect, and works filed under every combination.
"""

from __future__ import annotations

import duckdb
import pytest

from openlibrary.api.retrieval import _fetch_shelf, fetch_works
from openlibrary.pipeline.paths import ArtifactPaths

_TABLES = {
    "works": """
        SELECT * FROM (VALUES
            ('OL10W', 'The Sea Wolf'),
            ('OL11W', 'Filed under both keys'),
            ('OL12W', 'Co-authored, redirect second'),
            ('OL13W', 'Dangling author only'),
            ('OL14W', 'Redirect first, co-author second')
        ) t(work_key, title)
    """,
    "work_details": """
        SELECT * FROM (VALUES
            ('OL10W', NULL::VARCHAR, NULL::VARCHAR, 1904, ['Sea stories']::VARCHAR[])
        ) t(work_key, subtitle, description, declared_year, subjects)
    """,
    "authors": """
        SELECT * FROM (VALUES
            ('OL1A', 'Jack London'),
            ('OL2A', 'Co Author')
        ) t(author_key, name)
    """,
    # OL9A is the merged-away key: absent from `authors`, present in
    # `redirects` and in `work_authors`. OL8A is a cycle, OL7A is dangling.
    "redirects": """
        SELECT * FROM (VALUES
            ('author', 'OL9A', 'OL1A', 1::SMALLINT, false, false),
            ('author', 'OL8A', 'OL8A', 2::SMALLINT, true, false),
            ('author', 'OL7A', 'OL77A', 1::SMALLINT, false, true)
        ) t(entity, source_key, terminal_key, depth, is_cycle, is_dangling)
    """,
    "work_authors": """
        SELECT * FROM (VALUES
            ('OL10W', 'OL9A', 0::SMALLINT),
            ('OL11W', 'OL1A', 0::SMALLINT),
            ('OL11W', 'OL9A', 1::SMALLINT),
            ('OL12W', 'OL2A', 0::SMALLINT),
            ('OL12W', 'OL9A', 1::SMALLINT),
            ('OL13W', 'OL7A', 0::SMALLINT),
            ('OL13W', 'OL8A', 1::SMALLINT),
            ('OL14W', 'OL9A', 0::SMALLINT),
            ('OL14W', 'OL2A', 1::SMALLINT)
        ) t(work_key, author_key, position)
    """,
    "year_evidence": """
        SELECT * FROM (VALUES
            ('OL10W', 1904, 1904, 1905, 1904, 3, 5::BIGINT, 6::BIGINT)
        ) t(work_key, declared_year, min_edition_year, second_min_edition_year,
            modal_edition_year, modal_edition_year_count, edition_year_count, edition_count)
    """,
    "popularity": """
        SELECT * FROM (VALUES
            ('OL10W', 6, 40, 4, 4.1),
            ('OL11W', 2, 30, 1, 3.0),
            ('OL12W', 1, 20, 0, NULL::DOUBLE),
            ('OL14W', 1, 10, 0, NULL::DOUBLE)
        ) t(work_key, edition_count, readinglog_count, ratings_count, ratings_avg)
    """,
}


@pytest.fixture(scope="module")
def synthetic_paths(tmp_path_factory) -> ArtifactPaths:
    root = tmp_path_factory.mktemp("author-redirects")
    paths = ArtifactPaths(root=root, dump_date="2026-07-31")
    paths.version_dir.mkdir(parents=True)
    con = duckdb.connect()
    for name, select in _TABLES.items():
        con.execute(f"COPY ({select}) TO '{paths.table(name)}' (FORMAT PARQUET)")
    con.close()
    return paths


@pytest.fixture
def cur():
    con = duckdb.connect()
    handle = con.cursor()
    yield handle
    handle.close()
    con.close()


def _author_keys(record) -> list[str]:
    return [author.key.key for author in record.authors]


def test_a_work_whose_only_author_key_is_a_redirect_source_gets_the_terminal_author(
    cur, synthetic_paths
):
    record = fetch_works(cur, synthetic_paths, ["OL10W"])["OL10W"]
    assert record is not None
    assert _author_keys(record) == ["OL1A"]
    assert [author.name for author in record.authors] == ["Jack London"]


def test_a_work_filed_under_both_the_source_and_the_terminal_key_lists_the_author_once(
    cur, synthetic_paths
):
    record = fetch_works(cur, synthetic_paths, ["OL11W"])["OL11W"]
    assert _author_keys(record) == ["OL1A"]


def test_resolved_authors_keep_their_position_order(cur, synthetic_paths):
    records = fetch_works(cur, synthetic_paths, ["OL12W", "OL14W"])
    assert _author_keys(records["OL12W"]) == ["OL2A", "OL1A"]
    assert _author_keys(records["OL14W"]) == ["OL1A", "OL2A"]


def test_a_cycle_or_dangling_author_redirect_yields_no_author(cur, synthetic_paths):
    record = fetch_works(cur, synthetic_paths, ["OL13W"])["OL13W"]
    assert record is not None
    assert record.authors == []


def test_the_shelf_reaches_works_filed_under_the_merged_away_key_and_dedupes(cur, synthetic_paths):
    shelf = _fetch_shelf(cur, synthetic_paths, "OL1A", limit=500, offset=0)
    keys = [entry.key.key for entry in shelf]
    # Popularity order (readinglog 40, 30, 20, 10); OL11W once although it is
    # filed under both OL1A and OL9A; OL13W never (its keys are a cycle and a
    # dangling redirect, not London's).
    assert keys == ["OL10W", "OL11W", "OL12W", "OL14W"]


def test_the_shelf_pages_over_the_deduplicated_set(cur, synthetic_paths):
    first = _fetch_shelf(cur, synthetic_paths, "OL1A", limit=2, offset=0)
    second = _fetch_shelf(cur, synthetic_paths, "OL1A", limit=2, offset=2)
    assert [e.key.key for e in first] == ["OL10W", "OL11W"]
    assert [e.key.key for e in second] == ["OL12W", "OL14W"]
