from wikidata.pipeline import redirects
from wikidata.pipeline.redirects import iter_rows, parse_redirects

from .conftest import FIXTURES

REDIRECT = FIXTURES / "mini-redirect.sql"
PAGE = FIXTURES / "mini-page.sql"


def test_a_redirect_resolves_to_its_target():
    assert ("Q900101", "Q622400") in set(parse_redirects(REDIRECT, PAGE))


def test_a_two_hop_chain_resolves_to_its_end():
    assert ("Q900102", "Q622400") in set(parse_redirects(REDIRECT, PAGE))


def test_a_cycle_is_dropped():
    pairs = set(parse_redirects(REDIRECT, PAGE))
    assert not {q for pair in pairs for q in pair} & {"Q900103", "Q900104"}


def test_other_namespaces_and_interwiki_rows_are_ignored():
    pairs = set(parse_redirects(REDIRECT, PAGE))
    assert "Q900105" not in {source for source, _ in pairs}
    assert len(pairs) == 3


def test_tokenizer_handles_escaped_quotes_and_backslashes():
    rows = list(iter_rows(PAGE, "page"))
    assert rows[-1][2] == "Talk:It's, a \\ title"
    assert rows[-1][-1] == "en"
    assert rows[0][-1] is None


def test_a_multi_line_dump_yields_the_expected_pairs():
    # The real Wikimedia format: VALUES alone on its line, one tuple per line.
    assert set(parse_redirects(REDIRECT, PAGE)) == {
        ("Q900101", "Q622400"),
        ("Q900102", "Q622400"),
        ("Q900106", "Q12418"),
    }


def test_rows_come_from_every_insert_statement_in_both_forms():
    assert [r[0] for r in iter_rows(REDIRECT, "redirect")] == [
        "1001", "1002", "1003", "1004", "1009", "1006", "1007",
    ]  # fmt: skip


def test_a_tuple_spanning_lines_is_read_whole(tmp_path):
    path = tmp_path / "redirect.sql"
    path.write_text(
        "INSERT INTO `redirect` VALUES\n(1,0,'Q2','',''),(2,0,'Q\n3','',''),\n(3,0,'Q\n4','','');\n"
    )
    assert [r[0] for r in iter_rows(path, "redirect")] == ["1", "2", "3"]


def test_a_chain_past_the_hop_limit_is_dropped(tmp_path, monkeypatch):
    monkeypatch.setattr(redirects, "MAX_HOPS", 2)
    page = tmp_path / "page.sql"
    redirect = tmp_path / "redirect.sql"
    page.write_text("INSERT INTO `page` VALUES (1,0,'Q1',1,0),(2,0,'Q2',1,0),(3,0,'Q3',1,0);\n")
    redirect.write_text(
        "INSERT INTO `redirect` VALUES (1,0,'Q2','',NULL),(2,0,'Q3','',NULL),(3,0,'Q4','',NULL);\n"
    )
    # Q1 -> Q2 -> Q3 -> Q4 is three hops; Q2 and Q3 are within reach, Q1 is not.
    assert set(parse_redirects(redirect, page)) == {("Q2", "Q4"), ("Q3", "Q4")}
