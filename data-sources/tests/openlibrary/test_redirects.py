import gzip
import json

import pytest

from openlibrary.pipeline.authors import build_authors, stage_authors
from openlibrary.pipeline.derive import build_popularity, build_work_authors, build_year_evidence
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.editions import build_editions, stage_editions
from openlibrary.pipeline.gates import run_gates
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


def _dump_line(key: str | None, location: str) -> str:
    """One /type/redirect dump line. `key=None` omits the "key" field entirely,
    reproducing a malformed record like the one this branch already hit once
    in 1,790,272 real records."""
    payload = {"type": {"key": "/type/redirect"}, "location": location}
    if key is not None:
        payload["key"] = key
    row_key = key or "MISSING"
    return f"/type/redirect\t{row_key}\t1\t2020-01-01T00:00:00.000000\t{json.dumps(payload)}\n"


def test_a_null_key_record_does_not_mask_a_genuinely_unclosed_chain(tmp_path, fixture_dumps):
    """A record with no `$.key` puts a NULL into redirect_edges.source_path.
    `cursor_path IN (SELECT source_path FROM redirect_edges)` then evaluates
    NULL, not false, for any row whose cursor_path is not a literal match --
    which flips is_cycle from false to NULL for that row instead of leaving it
    false. gates.py's `NOT is_cycle` excludes NULL rows from the "unclosed"
    count, so a chain that genuinely never closed goes uncounted and the gate
    passes regardless of the data.

    The "genuinely unclosed" chain here exploits a real, separate quirk: an
    'other'-entity source (its own key matches none of works/authors/books)
    gets no prefix rule for a bare location, so "OL999999999X" is never
    rewritten to "/works/OL999999999X". The algorithm's raw-path comparison
    (source_path/cursor_path, always prefixed) never sees this as a match --
    is_cycle correctly stays false -- but the OUTPUT table strips prefixes
    before comparing (source_key/terminal_key), where the same bare string
    DOES collide with a real /works/ redirect's stripped source_key. That
    mismatch is exactly what gates.py's redirect_closure check exists to
    catch; this test only proves the NULL-key bug hides it, not that the
    'other'-entity gap itself is fixed here -- it isn't, and is out of scope.
    """
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())

    # Replace the shared fixture's redirects dump with a tiny synthetic one.
    lines = [
        _dump_line(None, "/works/OL_ORPHAN_TARGETW"),  # the NULL-key defect
        _dump_line("/languages/eng", "OL999999999X"),  # bare target, entity 'other'
        _dump_line("/works/OL999999999X", "/works/OL_FINAL_TARGETW"),
    ]
    with gzip.open(paths.dump("redirects"), "wt", encoding="utf-8") as fh:
        fh.writelines(lines)

    con = connect(paths, memory_limit="1GB")
    stage_works(con, paths)
    build_works(con, paths)
    stage_authors(con, paths)
    build_authors(con, paths)
    stage_editions(con, paths)
    build_editions(con, paths)
    build_work_authors(con, paths)
    build_redirects(con, paths)
    build_year_evidence(con, paths)
    build_popularity(con, paths)

    results = run_gates(con, paths, previous_report=None)
    closure = next(r for r in results if r.name == "redirect_closure")
    con.close()

    assert closure.observed["unclosed"] >= 1, closure.detail
    assert closure.status == "fail"
