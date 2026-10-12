"""Every assertion below names a FAILING case the corpus must keep. If one
breaks after a regeneration, restore the row; deleting the assertion returns
the guard it protects to being untestable."""

import json
from pathlib import Path

CORPUS = Path(__file__).parent / "sample.jsonl"


def _rows():
    for line in CORPUS.read_text(encoding="utf-8").splitlines():
        yield json.loads(line)


def _records(kind: str):
    return [r for r in _rows() if r["metadata"]["type"] == kind]


def test_corpus_stays_small_enough_to_commit():
    assert CORPUS.stat().st_size < 400_000


def test_corpus_holds_the_four_canaries():
    numbers = {r["metadata"]["oclc_number"].lstrip("0") for r in _rows()}
    assert {"1055766559", "1000415078", "1002380292", "1003236695"} <= numbers


def test_corpus_contains_a_non_book_format_title():
    assert any(
        r["metadata"]["record"].get("generalFormat") != "Book" for r in _records("title_json")
    )


def test_corpus_contains_a_book_with_no_isbn():
    assert any(
        r["metadata"]["record"].get("generalFormat") == "Book"
        and not r["metadata"]["record"].get("isbns")
        for r in _records("title_json")
    )


def test_corpus_contains_an_isbn_with_a_wrong_check_digit():
    from common.normalize import normalize_isbn

    bad = [
        v
        for r in _records("title_json") + _records("briefrecords_json")
        for v in (r["metadata"]["record"].get("isbns") or [])
        if (n := normalize_isbn(v)) is not None and not n.checksum_ok
    ]
    assert bad, "no ISBN in the corpus fails its check digit"


def test_corpus_contains_the_same_oclc_in_two_passes_with_different_genre():
    by_oclc: dict[str, set] = {}
    for r in _records("title_json"):
        by_oclc.setdefault(r["metadata"]["oclc_number"], set()).add(
            r["metadata"]["record"].get("genre")
        )
    assert any(len(genres) > 1 for genres in by_oclc.values())


def test_corpus_contains_a_brief_only_record():
    titles = {r["metadata"]["oclc_number"] for r in _records("title_json")}
    assert any(r["metadata"]["oclc_number"] not in titles for r in _records("briefrecords_json"))


def test_corpus_contains_a_redirect_chain_and_a_cycle():
    to = {
        r["metadata"]["oclc_number"].lstrip("0"): str(
            r["metadata"]["record"]["redirected_oclc_number"]
        )
        for r in _records("redirect_title_json")
    }
    assert any(t in to and to[t] != s for s, t in to.items()), "no chain"
    assert any(to.get(to[src]) == src for src in to), "no cycle"


def test_corpus_contains_an_english_record_with_french_headings():
    assert any(
        r["metadata"]["record"].get("catalogingLanguage") == "eng"
        and any(
            "Habitude" in s or "Romans" in s
            for s in (r["metadata"]["record"].get("subjectsText") or [])
        )
        for r in _records("title_json")
    )


def test_corpus_contains_two_holdings_summaries_for_one_number():
    counts: dict[str, int] = {}
    for r in _records("search_holdings_summary_all_editions"):
        counts[r["metadata"]["oclc_number"]] = counts.get(r["metadata"]["oclc_number"], 0) + 1
    assert max(counts.values()) >= 2


def test_corpus_contains_a_brief_record_whose_subjects_are_dicts():
    assert any(
        isinstance((r["metadata"]["record"].get("subjects") or [None])[0], dict)
        for r in _records("briefrecords_json")
    )


def test_later_holdings_row_has_the_largest_index_for_its_number():
    rows = [
        r
        for r in _records("search_holdings_summary_all_editions")
        if r["metadata"]["oclc_number"] == "0001055766559"
    ]

    def index(row):
        return int(row["metadata"]["from_filenames"][0].rsplit("/", 1)[-1])

    assert max(rows, key=index)["metadata"].get("_synthetic") == "later_holdings"
