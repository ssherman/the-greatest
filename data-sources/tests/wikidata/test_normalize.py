import pytest

from wikidata.pipeline.normalize import normalize_external_id, normalize_name


def test_normalize_name_folds_accents_and_case():
    assert normalize_name("Gabriel García Márquez") == normalize_name("gabriel garcia marquez")


def test_normalize_name_turns_punctuation_into_single_spaces():
    assert normalize_name("O'Brien, Flann") == "o brien flann"


def test_normalize_name_keeps_non_latin_scripts():
    assert normalize_name("Лев Толстой").startswith("лев толсто")


def test_isbn_hyphenated_isbn13():
    assert normalize_external_id("isbn", "978-0-385-47454-2") == "9780385474542"


def test_isbn10_becomes_isbn13():
    assert normalize_external_id("isbn", "0385474547") == "9780385474542"


def test_isbn10_with_x_check_digit():
    assert normalize_external_id("isbn", "0-8044-2957-X") == "9780804429573"


@pytest.mark.parametrize("bad", ["0385474548", "9780385474543", "12345", "not an isbn"])
def test_invalid_isbn_is_none(bad):
    assert normalize_external_id("isbn", bad) is None


def test_strip_spaces():
    assert normalize_external_id("strip_spaces", "0000 0001 2135 4208") == "0000000121354208"


def test_exact_is_untouched():
    assert normalize_external_id("exact", "24596756") == "24596756"


def test_unknown_kind_raises():
    with pytest.raises(ValueError):
        normalize_external_id("nope", "x")
