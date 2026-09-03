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


# --- the negative class -------------------------------------------------
#
# A corpus sampled from real data is almost all happy path. Everything below
# asserts that a specific FAILING case is still present, because each one is
# the only reason some guard in the pipeline has a test that can fail. If one
# of these breaks after a regeneration, the fix is to restore the row -- not to
# delete the assertion, which silently returns the guard above it to being
# untestable. See extract_fixtures.py's NEGATIVE_CLASS_WORKS.


def _editions_by_work() -> dict[str, list[dict]]:
    grouped: dict[str, list[dict]] = {}
    for _, doc in _docs("editions"):
        for work in doc.get("works") or []:
            key = (work.get("key") or "").removeprefix("/works/")
            if key:
                grouped.setdefault(key, []).append(doc)
    return grouped


def test_corpus_contains_an_isbn_with_a_wrong_check_digit():
    """Without one, `identifiers.checksum_ok` is `true` on every row in the
    corpus and its test can only assert that `false` is representable."""
    from common.normalize import normalize_isbn

    bad = [
        (key, value)
        for key, doc in _docs("editions")
        for field in ("isbn_10", "isbn_13")
        for value in (doc.get(field) or [])
        if (parsed := normalize_isbn(value)) is not None and not parsed.checksum_ok
    ]

    assert bad, "no ISBN in the corpus fails its check digit"


def test_corpus_contains_one_isbn_shared_by_two_different_works():
    """The reused-ISBN case: one identifier legitimately pointing at more than
    one work is the ambiguity `identifiers` exists to expose, and the thing a
    DISTINCT over that table must NOT collapse.

    Counted over CANONICAL ISBN-13, from both `isbn_10` and `isbn_13`, because
    that is what the pipeline stores. The corpus's shared identifier is written
    as the ISBN-10 `0028972457` on every one of the three editions involved and
    becomes `9780028972459` only after normalization -- reading the raw
    `isbn_13` field alone finds nothing and reports the class as missing.
    """
    from common.normalize import normalize_isbn

    works_by_isbn: dict[str, set[str]] = {}
    for _, doc in _docs("editions"):
        keys = {(w.get("key") or "").removeprefix("/works/") for w in (doc.get("works") or [])}
        for raw in (doc.get("isbn_13") or []) + (doc.get("isbn_10") or []):
            parsed = normalize_isbn(raw)
            if parsed and parsed.isbn13:
                works_by_isbn.setdefault(parsed.isbn13, set()).update(k for k in keys if k)

    shared = {isbn: works for isbn, works in works_by_isbn.items() if len(works) > 1}
    assert shared, "no ISBN in the corpus normalizes onto two different works"


def test_corpus_contains_two_works_that_fingerprint_identically():
    """title_fp_freq can only be > 1 if two works share a fingerprint, and
    every frequency guard downstream reads that column."""
    from common.normalize import fingerprint

    counts: dict[str, int] = {}
    for _, doc in _docs("works"):
        fp = fingerprint(doc.get("title"))
        if fp:
            counts[fp] = counts.get(fp, 0) + 1

    assert any(count == 2 for count in counts.values()), (
        "no title fingerprint in the corpus is shared by exactly two works"
    )


def test_corpus_can_push_a_title_fingerprint_past_the_frequency_guard():
    """Blocking rule 4 drops any fingerprint shared by more than
    MAX_TITLE_FP_FREQ works. Testing that guard needs one that is."""
    from common.normalize import fingerprint
    from openlibrary.eval.build_pool import MAX_TITLE_FP_FREQ

    counts: dict[str, int] = {}
    for _, doc in _docs("works"):
        fp = fingerprint(doc.get("title"))
        if fp:
            counts[fp] = counts.get(fp, 0) + 1

    assert max(counts.values()) > MAX_TITLE_FP_FREQ


def test_corpus_contains_a_title_in_a_non_latin_script():
    """Not merely a title with a character above U+2000 -- the corpus had six
    of those and every one was pure Latin, matching on a curly quote, a euro
    sign, or the combining half marks in "i︠a︡".

    Stricter than `assign_strata`'s own predicate on purpose. That one starts
    at U+024F, which also admits the Spacing Modifier Letters (U+02B0-U+02FF)
    that Latin romanizations use -- "Al Qurʻān", "Pipʻyŏng ŭisik ŭi tʻusido".
    Measured over the 126,330-book export, that costs 2 books of 3,744 claimed
    (0.1%), both Arabic transliterations, so the predicate is left alone. But
    a corpus assertion satisfied by a romanization would not notice if the
    genuinely-scripted seeds disappeared, so this starts at Greek (U+0370).
    """
    scripted = [
        (key, doc["title"])
        for key, doc in _docs("works")
        if any(ch.isalpha() and ord(ch) >= 0x0370 for ch in (doc.get("title") or ""))
    ]

    assert scripted, "no work in the corpus has a non-Latin-script title"


def test_corpus_contains_a_work_with_a_declared_year_and_no_editions():
    """year_evidence must still emit a row for a work whose only date evidence
    is its own first_publish_date. With no such work the assertion that it does
    is vacuous."""
    editions = _editions_by_work()
    dated_without_editions = [
        key.removeprefix("/works/")
        for key, doc in _docs("works")
        if doc.get("first_publish_date") and not editions.get(key.removeprefix("/works/"))
    ]

    assert dated_without_editions


def test_corpus_contains_a_work_redirect_that_dangles():
    """Every dangling redirect in the corpus used to be an AUTHOR, so
    redirects.py's work-entity branch had no positive case.

    The target must be neither a work nor another redirect: a target that
    redirects on is a CHAIN, and the synthetic two-node cycle already in the
    corpus satisfies a looser "points outside works.txt" reading while being
    marked `is_cycle` with a NULL terminal, which is not dangling at all.
    """
    work_keys = {key for key, _ in _docs("works")}
    redirect_keys = {key for key, _ in _docs("redirects")}
    dangling = [
        (key, doc["location"])
        for key, doc in _docs("redirects")
        if key.startswith("/works/")
        and doc.get("location", "").startswith("/works/")
        and doc["location"] not in work_keys
        and doc["location"] not in redirect_keys
    ]

    assert dangling, "no /works/ redirect in the corpus terminates outside works.txt"


def test_no_edition_is_attached_to_a_synthetic_work():
    """The synthetic works exist only to make one title fingerprint frequent.

    Their first key range, OL9990001W upward, turned out to be REAL Open
    Library key space -- the highest real numeric part in the 2026-07-31 dump
    is 45,845,863 -- and because the editions pass collects every edition of
    every fixture work, 51 real editions were pulled in and attached to them,
    handing synthetic works publish years and ISBNs they should never have.
    A synthetic work with an edition means the key range has collided again.
    """
    synthetic = {key for key, doc in _docs("works") if isinstance(doc.get("_synthetic"), str)}
    assert synthetic, "the synthetic frequent-title block is missing from works.txt"

    attached = [
        (edition_key, work.get("key"))
        for edition_key, doc in _docs("editions")
        for work in (doc.get("works") or [])
        if work.get("key") in synthetic
    ]

    assert attached == []
