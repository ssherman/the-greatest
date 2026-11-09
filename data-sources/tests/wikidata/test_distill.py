import json
import threading
from concurrent.futures.process import BrokenProcessPool

import duckdb
import pytest

from wikidata.pipeline import distill as distill_module
from wikidata.pipeline.distill import distill
from wikidata.pipeline.normalize import normalize_name
from wikidata.pipeline.paths import TABLES, WikidataPaths
from wikidata.pipeline.scan import iter_entities

from .conftest import FIXTURES

EDITION = "Q900001"
SCHOLARLY_ARTICLE = "Q900002"
MANGA_VOLUME = "Q900003"
TWO_HOP_NOVEL = "Q900005"
PAINTING = "Q12418"


def run(paths, config, threads=2):
    return distill(
        FIXTURES / "mini-all.json",
        FIXTURES / "mini-redirect.sql",
        FIXTURES / "mini-page.sql",
        paths,
        config,
        memory_limit="1GB",
        threads=threads,
    )


@pytest.fixture(scope="module")
def built(tmp_path_factory, config):
    paths = WikidataPaths(root=tmp_path_factory.mktemp("wikidata"), dump_date="2026-11-01")
    return paths, run(paths, config)


def rows(built, sql, table):
    paths, _ = built
    return duckdb.sql(sql.format(t=f"'{paths.staged(table)}'")).fetchall()


def qids(built, table):
    return {r[0] for r in rows(built, "SELECT qid FROM {t}", table)}


def test_every_table_is_written_to_staging_not_the_version_dir(built):
    paths, counts = built
    assert set(counts) == set(TABLES)
    assert all(paths.staged(t).exists() and not paths.table(t).exists() for t in TABLES)
    assert not paths.shards_dir.exists()


def test_items_hold_the_kept_entities(built):
    assert {
        "Q622400",  # Things Fall Apart
        EDITION,
        MANGA_VOLUME,
        TWO_HOP_NOVEL,
        "Q6691",  # Homer
        "Q155845",  # Achebe
        "Q7243",  # Tolstoy
        "Q1033",  # Nigeria: target of a kept item's P495
    } <= qids(built, "items")


def test_items_leave_out_the_article_and_the_painting(built):
    items = qids(built, "items")
    assert SCHOLARLY_ARTICLE not in items
    assert PAINTING not in items


def test_labels_hold_every_entity_including_the_painting(built):
    _, counts = built
    assert PAINTING in qids(built, "labels")
    assert counts["labels"] == len(list(iter_entities(FIXTURES / "mini-all.json")))


def test_external_ids_hold_the_normalized_isbn_and_viaf(built):
    pairs = rows(built, "SELECT property, value, qid FROM {t}", "external_ids")
    assert ("P212", "9780385474542", EDITION) in pairs
    assert ("P214", "24596756", "Q155845") in pairs


def test_links_hold_author_to_work_but_not_from_the_article(built):
    links = rows(built, "SELECT property, target, source FROM {t}", "links")
    assert ("P50", "Q155845", "Q622400") in links
    assert not [link for link in links if link[2] == SCHOLARLY_ARTICLE]


def test_names_index_an_alias_of_a_person(built):
    names = rows(built, "SELECT name, qid FROM {t}", "names")
    assert (normalize_name("Лев Толстой"), "Q7243") in names
    assert {q for _, q in names} <= qids(built, "items")


def test_nigeria_keeps_its_country_code(built):
    ((claims,),) = rows(built, "SELECT claims FROM {t} WHERE qid = 'Q1033'", "items")
    assert json.loads(claims)["P297"][0]["mainsnak"]["datavalue"]["value"] == "NG"


def test_redirects_keep_every_target_that_exists_in_the_dump(built):
    pairs = rows(built, "SELECT from_qid, to_qid FROM {t}", "redirects")
    # Q900106 redirects to the painting: not kept, but present in labels.
    assert pairs == [("Q900101", "Q622400"), ("Q900102", "Q622400"), ("Q900106", "Q12418")]


def test_an_isbn10_only_statement_is_stored_as_isbn13(built):
    pairs = rows(built, "SELECT property, value, qid FROM {t}", "external_ids")
    assert ("P957", "9780306406157", "Q900022") in pairs


@pytest.mark.parametrize(
    "table,keys",
    [
        ("items", "qid"),
        ("labels", "qid"),
        ("external_ids", "property, value, qid"),
        ("links", "property, target, source"),
        ("names", "name, qid"),
        ("redirects", "from_qid, to_qid"),
    ],
)
def test_every_table_is_sorted_by_its_key(built, table, keys):
    paths, _ = built
    stored = duckdb.sql(
        f"SELECT {keys} FROM (SELECT *, file_row_number AS pos"
        f" FROM read_parquet('{paths.staged(table)}', file_row_number = true)) ORDER BY pos"
    ).fetchall()
    assert stored
    assert stored == sorted(stored)


def test_items_row_groups_stay_small(built):
    paths, _ = built
    groups = duckdb.sql(
        f"SELECT row_group_num_rows FROM parquet_metadata('{paths.staged('items')}')"
    ).fetchall()
    assert all(n <= 10_000 for (n,) in groups)


def test_parallel_workers_produce_identical_tables(tmp_path, config, monkeypatch):
    # Seven-line batches spread the 43 fixture entities over several shards and workers.
    monkeypatch.setattr(distill_module, "BATCH_LINES", 7)
    contents = {}
    for threads in (1, 3):
        paths = WikidataPaths(root=tmp_path / f"t{threads}", dump_date="2026-11-01")
        run(paths, config, threads=threads)
        contents[threads] = {
            table: duckdb.sql(f"SELECT * FROM '{paths.staged(table)}' ORDER BY ALL").fetchall()
            for table in TABLES
        }
    assert contents[1] == contents[3]
    assert contents[3]["labels"]


def test_a_worker_killed_mid_batch_fails_the_build_instead_of_hanging(
    tmp_path, config, monkeypatch
):
    monkeypatch.setattr(distill_module, "BATCH_LINES", 7)
    monkeypatch.setenv("WIKIDATA_TEST_KILL_BATCH", "1")
    paths = WikidataPaths(root=tmp_path, dump_date="2026-11-01")
    outcome = {}

    def attempt():
        try:
            run(paths, config, threads=3)
        except BaseException as error:
            outcome["error"] = error

    # A thread with a join timeout, so a regression to a silent hang fails instead of stalling.
    thread = threading.Thread(target=attempt, daemon=True)
    thread.start()
    thread.join(timeout=60)
    assert not thread.is_alive(), "distill hung after a worker died"
    assert isinstance(outcome.get("error"), BrokenProcessPool)


def test_an_empty_dump_is_a_clear_error(tmp_path, config):
    empty = tmp_path / "empty.json"
    empty.write_text("[\n]\n")
    paths = WikidataPaths(root=tmp_path / "root", dump_date="2026-11-01")
    with pytest.raises(distill_module.EmptyDump):
        distill(
            empty,
            FIXTURES / "mini-redirect.sql",
            FIXTURES / "mini-page.sql",
            paths,
            config,
            memory_limit="1GB",
            threads=2,
        )


def test_rerunning_replaces_stale_shards(built, config):
    paths, counts = built
    paths.shards_dir.mkdir(parents=True)
    (paths.shards_dir / "shard_9999999.parquet").write_bytes(b"stale")
    assert run(paths, config) == counts


def test_rerunning_clears_spill_files_an_earlier_killed_build_left(built, config):
    paths, counts = built
    leftover = paths.tmp_dir / "duckdb_temp_storage_leftover.tmp"
    leftover.write_bytes(b"spill")
    assert run(paths, config) == counts
    assert not leftover.exists()


def test_a_single_oversized_entity_does_not_fail_the_shard_write(tmp_path, config):
    import orjson

    entity = {
        "id": "Q900999",
        "type": "item",
        "labels": {"en": {"language": "en", "value": "x" * (20 * 1024 * 1024)}},
        "descriptions": {},
        "aliases": {},
        "claims": {},
        "sitelinks": {},
    }
    distill_module._init_worker(config)
    written = distill_module._process_batch((0, [orjson.dumps(entity)], str(tmp_path)))
    assert written == 1
    assert (tmp_path / "shard_0000000.parquet").exists()
