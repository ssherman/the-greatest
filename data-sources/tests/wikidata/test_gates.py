import duckdb
import pytest

from wikidata.pipeline.distill import distill
from wikidata.pipeline.gates import gates_passed, run_gates
from wikidata.pipeline.paths import TABLES, WikidataPaths

from .conftest import FIXTURES


@pytest.fixture(scope="module")
def staged(tmp_path_factory, config):
    paths = WikidataPaths(root=tmp_path_factory.mktemp("gates"), dump_date="2026-11-01")
    counts = distill(
        FIXTURES / "mini-all.json",
        FIXTURES / "mini-redirect.sql",
        FIXTURES / "mini-page.sql",
        paths,
        config,
        memory_limit="1GB",
        threads=2,
    )
    return paths, counts


def by_name(results):
    return {r.name: r for r in results}


def copy_staged(paths, tmp_path, **replacements):
    copy = WikidataPaths(root=tmp_path, dump_date="2026-11-01")
    copy.ensure()
    for table in TABLES:
        select = replacements.get(table, f"SELECT * FROM '{paths.staged(table)}'")
        duckdb.sql(f"COPY ({select}) TO '{copy.staged(table)}' (FORMAT parquet)")
    return copy


def test_the_fixture_build_passes_with_the_fixture_switch(staged, config):
    paths, _ = staged
    results = run_gates(paths, config, None, fixture=True)
    assert gates_passed(results), [r for r in results if r.status == "fail"]
    assert by_name(results)["canaries"].status == "skipped"


def test_the_real_canaries_resolve_against_the_fixture(staged, config):
    paths, _ = staged
    assert by_name(run_gates(paths, config, None))["canaries"].status == "pass"


def test_a_table_at_half_its_previous_count_fails_row_counts(staged, config):
    paths, counts = staged
    previous = {**counts, "items": counts["items"] * 2}
    results = by_name(run_gates(paths, config, previous, fixture=True))
    assert results["row_counts"].status == "fail"
    assert "items" in results["row_counts"].detail


def test_an_excluded_type_in_items_fails(staged, config, tmp_path):
    paths, _ = staged
    copy = copy_staged(
        paths,
        tmp_path,
        items=f"SELECT * REPLACE (['Q13442814'] AS types) FROM '{paths.staged('items')}'"
        " WHERE qid = 'Q622400'",
    )
    results = by_name(run_gates(copy, config, None, fixture=True))
    assert results["no_excluded_types"].status == "fail"


def test_a_missing_canary_fails(staged, config, tmp_path):
    paths, _ = staged
    copy = copy_staged(
        paths, tmp_path, names=f"SELECT * FROM '{paths.staged('names')}' WHERE qid <> 'Q155845'"
    )
    assert by_name(run_gates(copy, config, None))["canaries"].status == "fail"
