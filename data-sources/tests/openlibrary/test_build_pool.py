import json

import pytest

from openlibrary.eval.build_pool import build_pool, load_books, naive_candidates
from openlibrary.eval.schema import STRATA, EvalBook
from openlibrary.pipeline.build import build
from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths


@pytest.fixture()
def artifact(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    build(tmp_path, dump_date="2026-07-31", download=False, memory_limit="1GB")
    return paths


@pytest.fixture()
def books_file(tmp_path, artifact):
    """Books built from the fixture works, so blocking has something to find."""
    con = connect(artifact, memory_limit="1GB")
    rows = con.execute(
        f"""
        SELECT w.work_key, w.title,
               list(a.name) FILTER (WHERE a.name IS NOT NULL) AS author_names
        FROM '{artifact.table("works")}' w
        LEFT JOIN '{artifact.table("work_authors")}' wa USING (work_key)
        LEFT JOIN '{artifact.table("authors")}' a USING (author_key)
        WHERE w.title <> 'Selected Poems'
        GROUP BY w.work_key, w.title
        ORDER BY w.work_key
        """
    ).fetchall()
    con.close()
    # Ordered, and with the synthetic block excluded by title: the corpus
    # carries 51 works titled "Selected Poems" purely to push one fingerprint
    # past MAX_TITLE_FP_FREQ (see extract_fixtures.py's
    # SYNTHETIC_FREQUENT_TITLE), and letting them in would make most of these
    # books the same title. The unordered LIMIT this replaced also made the set
    # depend on how many works the corpus happened to have.

    path = tmp_path / "books.jsonl"
    with path.open("w") as fh:
        for index, (work_key, title, author_names) in enumerate(rows, start=1):
            fh.write(
                json.dumps(
                    {
                        "book_id": index,
                        "title": title,
                        "subtitle": None,
                        "author_names": author_names or [],
                        "first_published_year": None,
                        "isbn13": [],
                        "isbn10": [],
                        "asin": [],
                        "goodreads_id": [],
                        "existing_ol_work_keys": [work_key] if index % 3 == 0 else [],
                        "existing_ol_author_keys": [],
                    }
                )
                + "\n"
            )
    return path


def test_load_books_parses_every_line(books_file):
    written = sum(1 for line in books_file.open() if line.strip())
    books = load_books(books_file)

    assert written > 0
    assert len(books) == written
    assert books[0].book_id == 1


def test_naive_blocking_finds_the_seeded_work(artifact, books_file):
    con = connect(artifact, memory_limit="1GB")
    books = load_books(books_file)
    candidates = naive_candidates(con, artifact, books)
    con.close()
    hit = [b for b in books if candidates.get(b.book_id)]
    assert hit, "naive blocking found nothing at all; the joins are wrong"


def test_every_candidate_records_which_rules_produced_it(artifact, books_file):
    con = connect(artifact, memory_limit="1GB")
    books = load_books(books_file)
    candidates = naive_candidates(con, artifact, books)
    con.close()
    for entries in candidates.values():
        for candidate in entries:
            assert candidate.rules, "a candidate with no rule is untraceable"
            assert set(candidate.rules) <= {
                "identifier",
                "existing_key",
                "author_title_fp",
                "title_fp",
            }


def test_candidates_carry_the_evidence_a_human_needs(artifact):
    """The labeller decides from these numbers, so they are asserted as values.

    `is not None` could not fail here: `title_fp_freq` and `edition_count` are
    ints defaulting to 0 and `title` comes from a NOT NULL join column, so the
    original assertions held however badly the evidence query was wired.
    """
    con = connect(artifact, memory_limit="1GB")
    book = EvalBook(book_id=1, title="Probe", existing_ol_work_keys=["OL3809593W"])
    candidates = naive_candidates(con, artifact, [book])
    con.close()

    (candidate,) = candidates[1]
    assert candidate.work_key == "OL3809593W"
    assert candidate.title == "The Illuminatus! Trilogy"
    assert candidate.title_fp_freq == 1
    assert (candidate.min_edition_year, candidate.modal_edition_year) == (1977, 2021)
    # reading-log and ratings counts are pinned exactly because swapping the
    # two columns in the evidence query is the mistake worth catching. They do
    # move when the corpus is regenerated -- reading-log.txt keeps the first
    # 200 rows that match ANY fixture work, so adding works redistributes them
    # (this work has read 89, 75 and 79 across three regenerations). A
    # regeneration already requires re-checking the corpus assertions; this
    # line goes with them.
    assert (candidate.edition_count, candidate.readinglog_count, candidate.ratings_count) == (
        9,
        79,
        15,
    )
    assert sorted(candidate.author_names) == ["Robert Anton Wilson", "Robert Shea"]


def test_the_title_fp_rule_is_guarded_by_frequency(artifact, books_file):
    con = connect(artifact, memory_limit="1GB")
    books = load_books(books_file)
    candidates = naive_candidates(con, artifact, books)
    con.close()
    for entries in candidates.values():
        for candidate in entries:
            if candidate.rules == ["title_fp"]:
                assert candidate.title_fp_freq <= 50


def test_identifier_registration_normalizes_local_values_before_joining(artifact):
    """`identifiers.parquet` stores values canonicalized via isbn13_sql /
    isbn10_sql / asin_sql / goodreads_sql (editions.py). Rule 1's join is exact
    equality, so a locally-stored value in any other form -- hyphenated,
    slugged, mixed-case -- must be pushed through the matching Python
    normalizer before it is registered, or it silently misses.

    OL100077W and OL104728W are real work keys from the committed fixture
    corpus (see test_fixture_corpus.py); their canonical identifiers were
    confirmed by querying the built fixture artifact directly.
    """
    con = connect(artifact, memory_limit="1GB")
    book = EvalBook(
        book_id=999,
        title="Probe Book",
        isbn13=["978-0-385-90442-1"],  # hyphenated; canonical: 9780385904421
        isbn10=["052105818x"],  # lowercase check digit; canonical: 052105818X
        goodreads_id=["30338.The_Great_Gatsby"],  # slugged; canonical: 30338
    )
    candidates = naive_candidates(con, artifact, [book])
    con.close()

    hit_keys = {c.work_key for c in candidates.get(999, []) if "identifier" in c.rules}
    assert "OL100077W" in hit_keys, "hyphenated isbn13 / slugged goodreads did not join"
    assert "OL104728W" in hit_keys, "lowercase-x isbn10 did not join"


def test_build_pool_writes_jsonl_and_reports_per_stratum_counts(artifact, books_file, tmp_path):
    con = connect(artifact, memory_limit="1GB")
    out = tmp_path / "pool.jsonl"
    counts = build_pool(con, artifact, books_file, out)
    con.close()

    assert out.exists()
    assert set(counts) <= set(STRATA)
    lines = out.read_text().splitlines()
    assert len(lines) == sum(counts.values())
    first = json.loads(lines[0])
    assert first["stratum"] in STRATA
    assert "case_id" in first


def test_the_pool_builder_does_not_import_the_matcher():
    """The evaluation set must not be reshaped by tuning the thing it judges.

    Checked against actual IMPORT STATEMENTS rather than a bare substring
    search. A substring check collides with the module docstring that explains
    why the duplication is deliberate -- and that explanation is the single
    thing most likely to stop a future maintainer seeing duplicated SQL and
    "cleaning it up". The test should forbid the import, not the word.
    """
    import ast
    import inspect

    from openlibrary.eval import build_pool

    tree = ast.parse(inspect.getsource(build_pool))
    imported: set[str] = set()
    for node in ast.walk(tree):
        if isinstance(node, ast.Import):
            imported.update(alias.name for alias in node.names)
        elif isinstance(node, ast.ImportFrom) and node.module:
            imported.add(node.module)

    offenders = sorted(name for name in imported if "matcher" in name)
    assert offenders == [], f"build_pool must not import the matcher: {offenders}"


def test_the_frequency_guard_keeps_a_crowded_title_out_of_the_title_fp_rule(artifact):
    """Rule 4 must produce NOTHING for a title 51 works share.

    The guard exists because one degenerate key produced a 604,144-row join,
    and until the corpus carried a fingerprint above MAX_TITLE_FP_FREQ the
    guard could be deleted without a single test noticing: the old check only
    looked at candidates that had already been returned.
    """
    con = connect(artifact, memory_limit="1GB")
    book = EvalBook(book_id=1, title="Selected Poems")
    candidates = naive_candidates(con, artifact, [book])
    con.close()

    assert candidates.get(1, []) == []


def test_a_title_below_the_frequency_guard_still_blocks(artifact):
    """The control: without it the rule could be 'never return anything from
    title_fp' and the guard test above would still pass."""
    con = connect(artifact, memory_limit="1GB")
    book = EvalBook(book_id=1, title="The establishment clause")
    candidates = naive_candidates(con, artifact, [book])
    con.close()

    by_key = {c.work_key: c for c in candidates.get(1, [])}
    assert {"OL108593W", "OL269642W"} <= set(by_key)
    assert "title_fp" in by_key["OL108593W"].rules
