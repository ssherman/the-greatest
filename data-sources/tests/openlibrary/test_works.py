import duckdb
import pytest

from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.paths import ArtifactPaths
from openlibrary.pipeline.works import _DECLARED_YEAR_PATTERN, build_works, stage_works


@pytest.fixture()
def built(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    con = connect(paths, memory_limit="1GB")
    staged = stage_works(con, paths)
    counts = build_works(con, paths)
    yield con, paths, staged, counts
    con.close()


def test_staging_reads_every_work_line(built):
    _, _, staged, _ = built
    assert staged > 0


def test_works_table_has_one_row_per_work(built):
    con, paths, staged, counts = built
    assert counts["works"] == staged
    (distinct,) = con.execute(
        f"SELECT count(DISTINCT work_key) FROM '{paths.table('works')}'"
    ).fetchone()
    assert distinct == staged


def test_description_object_is_unwrapped_to_its_text(built):
    con, paths, _, _ = built
    rows = con.execute(
        f"SELECT description FROM '{paths.table('work_details')}' WHERE description IS NOT NULL"
    ).fetchall()
    assert rows, "no descriptions survived; the object/string shape is being mishandled"
    for (description,) in rows:
        # A serialized {"type": ..., "value": ...} object would start with '{'.
        assert not description.lstrip().startswith('{"type"')


def test_three_title_fingerprints_are_populated(built):
    con, paths, _, _ = built
    row = con.execute(
        f"SELECT title, title_fp, title_fp_nosub, title_fp_noart "
        f"FROM '{paths.table('works')}' WHERE title_fp <> '' LIMIT 1"
    ).fetchone()
    assert row is not None
    assert all(value is not None for value in row)


def test_title_fp_freq_counts_shared_fingerprints(built):
    con, paths, _, _ = built
    (bad,) = con.execute(
        f"""
        SELECT count(*) FROM (
          SELECT title_fp, count(*) AS actual, any_value(title_fp_freq) AS stored
          FROM '{paths.table("works")}'
          GROUP BY title_fp
        ) WHERE actual <> stored
        """
    ).fetchone()
    assert bad == 0


def test_author_count_is_stored_and_malformed_entries_are_dropped(built):
    con, paths, _, counts = built
    # The corpus contains at least one work whose author list has an entry with
    # no "author" key (352 such entries per 300,000 works in the real dump).
    assert counts["dropped_author_entries"] >= 1
    (bad,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('works')}' WHERE author_count IS NULL"
    ).fetchone()
    assert bad == 0


def test_work_details_holds_only_rows_with_something_in_them(built):
    con, paths, _, _ = built
    (empty,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table("work_details")}'
        WHERE subtitle IS NULL AND description IS NULL
          AND first_publish_date_raw IS NULL AND (subjects IS NULL OR len(subjects) = 0)
        """
    ).fetchone()
    assert empty == 0


def test_works_skeleton_does_not_carry_subjects_or_description(built):
    con, paths, _, _ = built
    columns = {
        row[0] for row in con.execute(f"DESCRIBE SELECT * FROM '{paths.table('works')}'").fetchall()
    }
    # Blocking queries read only narrow columns; that is what makes columnar
    # storage pay, and it is the opposite of the previous approach.
    assert "subjects" not in columns
    assert "description" not in columns


def test_last_modified_is_a_date_not_text(built):
    con, paths, _, _ = built
    types = {
        row[0]: row[1]
        for row in con.execute(f"DESCRIBE SELECT * FROM '{paths.table('works')}'").fetchall()
    }
    assert types["last_modified"] == "DATE"


def test_declared_year_is_never_implausibly_small(built):
    # Regression guard for a bug where a free-text `first_publish_date_raw`
    # (e.g. "December 31, 1991") was parsed by taking its FIRST digit run,
    # yielding the day instead of the year. None of the fixture dates are
    # free text, so this passes on today's fixture corpus either way; the
    # table-driven check below exercises the regex directly against the
    # inputs that actually distinguish the old pattern from the fix.
    con, paths, _, _ = built
    (bad,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('work_details')}' WHERE declared_year < 1000"
    ).fetchone()
    assert bad == 0


@pytest.mark.parametrize(
    ("raw", "expected"),
    [
        ("December 31, 1991", 1991),  # old pattern took the day: 31
        ("1904", 1904),
        ("-350", -350),  # ancient/BCE work
        ("1991-1995", 1991),  # a range: the year wins, not the first digit run
        ("ca. 1900", 1900),
        ("31", None),  # no 4-digit run and no sign -- nothing plausible
        ("19uu", None),  # OCR/placeholder junk, only 2 real digits
        ("July 3, 2003", 2003),  # old pattern took the day: 3
    ],
)
def test_declared_year_regex_extracts_the_year_not_the_first_digit_run(raw, expected):
    # Exercises the production regex (openlibrary.pipeline.works._DECLARED_YEAR_PATTERN)
    # directly against `first_publish_date_raw` shapes seen in the real dump, without
    # needing a matching fixture row. Restoring the old pattern, `(-?\d{1,4})`, fails
    # this on "December 31, 1991", "July 3, 2003", "31", and "19uu".
    con = duckdb.connect()
    (value,) = con.execute(
        f"SELECT TRY_CAST(regexp_extract(?, '{_DECLARED_YEAR_PATTERN}', 1) AS INTEGER)",
        [raw],
    ).fetchone()
    con.close()
    assert value == expected
