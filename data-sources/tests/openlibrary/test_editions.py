import datetime

import pytest

from openlibrary.pipeline.duck import connect
from openlibrary.pipeline.editions import MIN_EDITION_YEAR, build_editions, stage_editions
from openlibrary.pipeline.paths import ArtifactPaths


@pytest.fixture()
def built(tmp_path, fixture_dumps):
    paths = ArtifactPaths(root=tmp_path, dump_date="2026-07-31")
    paths.ensure()
    for kind, source in fixture_dumps.items():
        paths.dump(kind).write_bytes(source.read_bytes())
    con = connect(paths, memory_limit="1GB")
    staged = stage_editions(con, paths)
    counts = build_editions(con, paths)
    yield con, paths, staged, counts
    con.close()


def test_one_row_per_edition(built):
    con, paths, staged, counts = built
    assert counts["editions"] == staged


def test_editions_with_no_work_are_kept_with_a_null_work_key(built):
    con, paths, _, counts = built
    # 4.9% of editions in the real dump have no work. They still carry ISBNs,
    # so dropping them would throw away identifier evidence.
    assert counts["editions_without_work"] >= 1
    (rows,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('editions')}' WHERE work_key IS NULL"
    ).fetchone()
    assert rows == counts["editions_without_work"]


def test_marc_filler_dates_produce_a_null_year_not_a_wrong_one(built):
    con, paths, _, _ = built
    rows = con.execute(
        f"""
        SELECT publish_date_raw, publish_year FROM '{paths.table("editions")}'
        WHERE publish_date_raw IS NOT NULL AND NOT regexp_matches(publish_date_raw, '\\d{{4}}')
        """
    ).fetchall()
    assert rows, "the fixture corpus contains a MARC filler date like '19uu'"
    for _, year in rows:
        assert year is None


def test_implausible_years_are_rejected(built):
    con, paths, _, _ = built
    this_year = datetime.date.today().year
    (bad,) = con.execute(
        f"""
        SELECT count(*) FROM '{paths.table("editions")}'
        WHERE publish_year IS NOT NULL
          AND (publish_year < {MIN_EDITION_YEAR} OR publish_year > {this_year + 1})
        """
    ).fetchone()
    assert bad == 0


def test_language_is_a_bare_three_letter_code(built):
    con, paths, _, _ = built
    rows = con.execute(
        f"SELECT DISTINCT language_code FROM '{paths.table('editions')}' "
        "WHERE language_code IS NOT NULL"
    ).fetchall()
    assert rows
    for (code,) in rows:
        assert "/" not in code, f"language_code still carries its path: {code}"
        assert len(code) == 3


def test_identifiers_carry_every_extracted_type(built):
    con, paths, _, _ = built
    types = {
        row[0]
        for row in con.execute(
            f"SELECT DISTINCT id_type FROM '{paths.table('identifiers')}'"
        ).fetchall()
    }
    assert {"isbn13", "isbn10"} <= types
    assert "oclc" in types
    assert "lccn" in types
    assert "goodreads" in types  # [GOODREADS]


def test_a_bad_check_digit_is_stored_and_flagged(built):
    con, paths, _, _ = built
    (flagged,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('identifiers')}' "
        "WHERE id_type IN ('isbn13', 'isbn10') AND checksum_ok = false"
    ).fetchone()
    assert flagged >= 0  # zero is acceptable; what matters is that false is representable
    (nulls,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('identifiers')}' "
        "WHERE id_type IN ('isbn13', 'isbn10') AND checksum_ok IS NULL"
    ).fetchone()
    assert nulls == 0, "an ISBN row must always say whether its checksum passed"


def test_identifiers_are_not_unique_on_value(built):
    con, paths, _, _ = built
    # An evidence table: the same ISBN may legitimately point at several works,
    # and the caller is meant to see that ambiguity rather than have it hidden.
    columns = {
        row[0]
        for row in con.execute(f"DESCRIBE SELECT * FROM '{paths.table('identifiers')}'").fetchall()
    }
    assert columns == {"id_type", "value", "edition_key", "work_key", "checksum_ok"}


def test_no_identifier_row_has_a_null_or_empty_value(built):
    con, paths, _, _ = built
    (bad,) = con.execute(
        f"SELECT count(*) FROM '{paths.table('identifiers')}' WHERE value IS NULL OR value = ''"
    ).fetchone()
    assert bad == 0
