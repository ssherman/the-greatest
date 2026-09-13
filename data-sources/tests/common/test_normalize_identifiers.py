import pytest

from common.normalize import (
    IDENTIFIER_TYPES,
    normalize_asin,
    normalize_goodreads,
    normalize_isbn,
    normalize_lccn,
    normalize_oclc,
)


def test_identifier_types_are_declared():
    assert IDENTIFIER_TYPES == ("isbn13", "isbn10", "oclc", "lccn", "asin", "goodreads")


def test_valid_isbn10_converts_to_isbn13():
    result = normalize_isbn("0-306-40615-2")
    assert result.isbn10 == "0306406152"
    assert result.isbn13 == "9780306406157"
    assert result.checksum_ok is True


def test_isbn10_with_x_check_digit():
    result = normalize_isbn("043942089x")
    assert result.isbn10 == "043942089X"
    assert result.checksum_ok is True


def test_valid_isbn13_back_converts_to_isbn10_when_prefixed_978():
    result = normalize_isbn("978-0-306-40615-7")
    assert result.isbn13 == "9780306406157"
    assert result.isbn10 == "0306406152"
    assert result.checksum_ok is True


def test_isbn13_prefixed_979_has_no_isbn10():
    result = normalize_isbn("9791234567896")
    assert result.isbn13 == "9791234567896"
    assert result.isbn10 is None


def test_bad_check_digit_is_kept_and_flagged_not_dropped():
    # Evidence table: a wrong ISBN in Open Library is a fact about Open Library.
    result = normalize_isbn("0306406153")
    assert result.isbn10 == "0306406153"
    assert result.checksum_ok is False


def test_isbn_of_impossible_length_returns_none():
    assert normalize_isbn("12345") is None
    assert normalize_isbn("") is None
    assert normalize_isbn(None) is None


def test_oclc_strips_prefixes_and_leading_zeros():
    assert normalize_oclc("ocm00012345") == "12345"
    assert normalize_oclc("ocn987654321") == "987654321"
    assert normalize_oclc("on1234567890") == "1234567890"
    assert normalize_oclc("(OCoLC)00012345") == "12345"
    assert normalize_oclc("12345") == "12345"
    assert normalize_oclc("not-a-number") is None


def test_lccn_normalization_follows_the_loc_rules():
    # Space and slash removed; the serial part after a hyphen is zero-padded to 6.
    assert normalize_lccn("n 78-890351") == "n78890351"
    assert normalize_lccn("n78-890351") == "n78890351"
    assert normalize_lccn("   85000002 ") == "85000002"
    assert normalize_lccn("agr 62000298//r862") == "agr62000298"
    assert normalize_lccn("") is None


def test_asin_is_ten_uppercase_alphanumerics():
    assert normalize_asin("b000fc1abc") == "B000FC1ABC"
    assert normalize_asin("0306406152") == "0306406152"
    assert normalize_asin("too-short") is None


def test_goodreads_id_is_digits_only():
    assert normalize_goodreads("4671") == "4671"
    assert normalize_goodreads("4671.The_Great_Gatsby") == "4671"
    assert normalize_goodreads("abc") is None


@pytest.mark.parametrize("raw", ["", None, "   "])
def test_blank_inputs_normalize_to_none(raw):
    assert normalize_oclc(raw) is None
    assert normalize_lccn(raw) is None
    assert normalize_asin(raw) is None
    assert normalize_goodreads(raw) is None
