import duckdb
import pytest

from common.normalize import (
    asin_sql,
    fingerprint,
    fingerprint_sql,
    goodreads_sql,
    isbn13_sql,
    isbn_checksum_ok_sql,
    lccn_sql,
    normalize_asin,
    normalize_goodreads,
    normalize_isbn,
    normalize_lccn,
    normalize_oclc,
    oclc_sql,
    title_fingerprints,
    title_noart_sql,
    title_nosub_sql,
)

# Adversarial inputs, chosen to hit every branch of Unicode folding that has
# ever differed between an ICU-backed SQL engine and Python's unicodedata.
CORPUS = [
    "The Great Gatsby",
    "Ulysses: A Novel",
    "Dune; or, The Spice",
    "Hamlet (Arden Edition)",
    "It: A Novel",
    "The Sea",
    "!!!",
    "99 Франков",
    "Les Misérables",
    "L'Étranger",
    "Æsop's Fables",
    "Straße",
    "Þórr",
    "İstanbul",
    "ÅNGSTRÖM",
    "définitivement",  # combining acute, as it appears in the dumps
    "Hölderlin",
    "naïve café",
    "Ω mega",
    "日本語のタイトル",
    "The\xa0Hobbit",
    "O'Brien—Vol. II",
    "ß big",
    "ǅ title",
    "ＦＵＬＬＷＩＤＴＨ",
    "  spaced   out  ",
]


@pytest.fixture(scope="module")
def con():
    connection = duckdb.connect()
    yield connection
    connection.close()


@pytest.mark.parametrize("raw", CORPUS)
def test_fingerprint_matches_duckdb(con, raw):
    (sql_value,) = con.execute("SELECT " + fingerprint_sql("?"), [raw]).fetchone()
    assert sql_value == fingerprint(raw), f"SQL/Python divergence on {raw!r}"


@pytest.mark.parametrize("raw", CORPUS)
def test_nosub_variant_matches_duckdb(con, raw):
    (sql_value,) = con.execute("SELECT " + title_nosub_sql("?"), [raw, raw, raw]).fetchone()
    assert sql_value == title_fingerprints(raw).nosub, f"nosub divergence on {raw!r}"


@pytest.mark.parametrize("raw", CORPUS)
def test_noart_variant_matches_duckdb(con, raw):
    (sql_value,) = con.execute("SELECT " + title_noart_sql("?"), [raw, raw, raw]).fetchone()
    assert sql_value == title_fingerprints(raw).noart, f"noart divergence on {raw!r}"


ISBN_CORPUS = [
    "0-306-40615-2",
    "0306406152",
    "043942089x",
    "978-0-306-40615-7",
    "9780306406157",
    "9791234567896",
    "0306406153",  # bad check digit
    "12345",  # impossible length
    "",
]

OTHER_CORPUS = [
    "ocm00012345",
    "(OCoLC)00012345",
    "n 78-890351",
    "agr 62000298//r862",
    "b000fc1abc",
    "4671.The_Great_Gatsby",
    "",
]


@pytest.mark.parametrize("raw", ISBN_CORPUS)
def test_isbn13_matches_duckdb(con, raw):
    (sql_value,) = con.execute("SELECT " + isbn13_sql("?"), [raw] * 13).fetchone()
    expected = normalize_isbn(raw)
    assert sql_value == (expected.isbn13 if expected else None)


@pytest.mark.parametrize("raw", ISBN_CORPUS)
def test_isbn_checksum_flag_matches_duckdb(con, raw):
    (sql_value,) = con.execute("SELECT " + isbn_checksum_ok_sql("?"), [raw] * 9).fetchone()
    expected = normalize_isbn(raw)
    assert sql_value == (expected.checksum_ok if expected else None)


@pytest.mark.parametrize("raw", OTHER_CORPUS)
def test_scalar_identifier_normalizers_match_duckdb(con, raw):
    for sql_builder, py_fn, binding_count in (
        (oclc_sql, normalize_oclc, 3),
        (lccn_sql, normalize_lccn, 14),
        (asin_sql, normalize_asin, 2),
        (goodreads_sql, normalize_goodreads, 2),
    ):
        (sql_value,) = con.execute("SELECT " + sql_builder("?"), [raw] * binding_count).fetchone()
        assert sql_value == py_fn(raw), f"{sql_builder.__name__} diverged on {raw!r}"
