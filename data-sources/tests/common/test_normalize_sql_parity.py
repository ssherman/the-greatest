import duckdb
import pytest

from common.normalize import (
    fingerprint,
    fingerprint_sql,
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
