import gzip
import json
import re
from pathlib import Path

FIXTURE_DIR = Path(__file__).parent


def _docs(name: str):
    for line in (FIXTURE_DIR / f"{name}.txt").read_text(encoding="utf-8").splitlines():
        parts = line.split("\t", 4)
        if len(parts) == 5:
            yield parts[1], json.loads(parts[4])


def test_every_fixture_file_is_non_empty():
    for name in ("works", "authors", "editions", "redirects", "ratings", "reading-log"):
        assert (FIXTURE_DIR / f"{name}.txt").stat().st_size > 0, name


def test_total_corpus_stays_small_enough_to_commit():
    total = sum(
        (FIXTURE_DIR / f"{n}.txt").stat().st_size
        for n in ("works", "authors", "editions", "redirects", "ratings", "reading-log")
    )
    assert total < 4_000_000, f"fixture corpus grew to {total:,} bytes"


def test_seed_collision_works_are_present():
    # OL15331408W, the original omnibus seed, is not one of these: Open Library merged it into
    # OL3809593W on 2026-01-04, before this dump was taken. See
    # test_the_stale_omnibus_key_is_present_as_a_redirect for that key's own coverage.
    keys = {key.removeprefix("/works/") for key, _ in _docs("works")}
    for seed in ("OL3809593W", "OL2014226W", "OL81205W", "OL8331643W"):
        assert seed in keys, f"{seed} missing from the works fixture"


def test_corpus_contains_a_description_object_and_a_description_string():
    kinds = {type(doc.get("description")).__name__ for _, doc in _docs("works")}
    assert "dict" in kinds
    assert "str" in kinds


def test_corpus_contains_an_author_entry_with_no_author_key():
    found = any(
        isinstance(entry, dict) and "author" not in entry
        for _, doc in _docs("works")
        for entry in (doc.get("authors") or [])
    )
    assert found


def test_the_stale_omnibus_key_is_present_as_a_redirect():
    """Our books store OL15331408W; Open Library merged it into OL3809593W on
    2026-01-04. It is a real member of the 9.9% of stored keys that no longer
    resolve, and carrying it here is what gives the redirect path a genuine
    case rather than a synthetic one."""
    locations = {key: doc.get("location") for key, doc in _docs("redirects")}
    assert locations.get("/works/OL15331408W") == "/works/OL3809593W"


def test_corpus_contains_a_redirect_cycle():
    locations = {key: doc.get("location") for key, doc in _docs("redirects")}
    cycle = any(locations.get(locations.get(k)) == k for k in locations)
    assert cycle, "no cycle in the redirect fixture; the cycle gate has no positive case"


def test_corpus_contains_an_edition_with_no_work():
    assert any(not doc.get("works") for _, doc in _docs("editions"))


def test_corpus_contains_a_marc_filler_publish_date():
    assert any(
        doc.get("publish_date") and not re.search(r"\d{4}", str(doc["publish_date"]))
        for _, doc in _docs("editions")
    )


def test_fixture_dumps_gzip_correctly(fixture_dumps):
    for name, path in fixture_dumps.items():
        with gzip.open(path, "rt", encoding="utf-8") as fh:
            assert fh.readline(), f"{name} gzipped to an empty file"
