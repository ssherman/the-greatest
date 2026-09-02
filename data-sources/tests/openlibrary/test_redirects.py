import pytest

from openlibrary.pipeline.authors import build_authors, stage_authors
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths
from openlibrary.pipeline.redirects import MAX_REDIRECT_DEPTH, build_redirects
from openlibrary.pipeline.works import build_works, stage_works


@pytest.fixture()
def built(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    con = connect(paths, memory_limit="1GB")
    stage_works(con, paths)
    build_works(con, paths)
    stage_authors(con, paths)
    build_authors(con, paths)
    counts = build_redirects(con, paths)
    yield con, paths, counts
    con.close()


def test_every_source_key_appears_exactly_once(built):
    con, paths, counts = built
    (distinct,) = con.execute(
        f"SELECT count(DISTINCT source_key) FROM '{paths.table('redirects')}'"
    ).fetchone()
    assert distinct == counts["redirects"]


def test_a_multi_hop_chain_resolves_to_its_terminal(built):
    con, paths, _ = built
    row = con.execute(
        f"""
        SELECT source_key, terminal_key, depth FROM '{paths.table("redirects")}'
        WHERE depth >= 3 AND NOT is_cycle LIMIT 1
        """
    ).fetchone()
    assert row is not None, "the fixture corpus contains a chain of depth >= 3"
    source_key, terminal_key, _ = row
    assert terminal_key is not None
    assert terminal_key != source_key


def test_a_terminal_is_never_itself_a_redirect_source(built):
    con, paths, _ = built
    (unclosed,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table("redirects")}' r
        WHERE NOT r.is_cycle
          AND r.terminal_key IN (SELECT source_key FROM '{paths.table("redirects")}')
        """
    ).fetchone()
    assert unclosed == 0, "a chain did not close: a terminal is itself redirected"


def test_a_cycle_is_flagged_and_has_no_terminal(built):
    con, paths, counts = built
    assert counts["cycles"] >= 2, "the fixture corpus carries a two-node cycle"
    (bad,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('redirects')}' "
        "WHERE is_cycle AND terminal_key IS NOT NULL"
    ).fetchone()
    assert bad == 0


def test_a_dangling_terminal_is_flagged_not_silently_dropped(built):
    con, paths, counts = built
    assert counts["dangling"] >= 1
    (bad,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table("redirects")}'
        WHERE is_dangling AND entity = 'work'
          AND terminal_key IN (SELECT work_key FROM '{paths.table("works")}')
        """
    ).fetchone()
    assert bad == 0


def test_depth_never_exceeds_the_cap(built):
    con, paths, counts = built
    assert counts["max_depth"] <= MAX_REDIRECT_DEPTH
