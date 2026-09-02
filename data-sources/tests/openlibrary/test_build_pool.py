import json

import pytest

from openlibrary.eval.build_pool import build_pool, load_books, naive_candidates
from openlibrary.eval.schema import STRATA
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
        GROUP BY w.work_key, w.title
        LIMIT 40
        """
    ).fetchall()
    con.close()
    # The committed fixture corpus (Tasks 1-17, not this task's to change) has
    # exactly 34 works, fewer than the LIMIT 40 above asks for -- so this
    # fixture yields 34 books, not 40. See test_fixture_corpus.py for the
    # corpus's own accounting of what it contains.

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
    books = load_books(books_file)
    assert len(books) == 34
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


def test_candidates_carry_the_evidence_a_human_needs(artifact, books_file):
    con = connect(artifact, memory_limit="1GB")
    books = load_books(books_file)
    candidates = naive_candidates(con, artifact, books)
    con.close()
    every = [c for entries in candidates.values() for c in entries]
    assert every
    sample = every[0]
    assert sample.title is not None
    assert sample.title_fp_freq is not None
    assert sample.edition_count is not None


def test_the_title_fp_rule_is_guarded_by_frequency(artifact, books_file):
    con = connect(artifact, memory_limit="1GB")
    books = load_books(books_file)
    candidates = naive_candidates(con, artifact, books)
    con.close()
    for entries in candidates.values():
        for candidate in entries:
            if candidate.rules == ["title_fp"]:
                assert candidate.title_fp_freq <= 50


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
