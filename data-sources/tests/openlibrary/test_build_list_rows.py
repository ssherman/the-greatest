from openlibrary.eval.build_list_rows import (
    ListRow,
    load_rows,
    select_rows,
    split_authors,
    to_book,
)


def test_split_authors_splits_on_and_ampersand_and_semicolon():
    assert split_authors("Jaime Hernandez and Gilbert Hernandez") == [
        "Jaime Hernandez",
        "Gilbert Hernandez",
    ]
    assert split_authors("A. Smith & B. Jones; C. Lee") == ["A. Smith", "B. Jones", "C. Lee"]


def test_split_authors_keeps_a_comma_inside_one_name():
    # "Jr." and "Last, First" forms carry commas; commas are never split points.
    assert split_authors("Martin Luther King, Jr.") == ["Martin Luther King, Jr."]


def test_split_authors_accepts_a_list_and_drops_blanks():
    assert split_authors(["Toni Morrison", " ", ""]) == ["Toni Morrison"]
    assert split_authors(None) == []


def _row(item, rank, book, **kw):
    return ListRow(
        list_item_id=item,
        md5_rank=rank,
        title=kw.get("title", f"T{item}"),
        authors="A",
        book_id=book,
        book_ol_work_keys=kw.get("keys", []),
    )


def test_select_rows_skips_the_spike_ranks_and_takes_distinct_books_in_rank_order():
    rows = [_row(1, 1, 10), _row(2, 201, 11), _row(3, 202, 11), _row(4, 203, 12), _row(5, 150, 13)]
    picked = select_rows(rows, skip_ranks_through=200, n=2)
    assert [r.list_item_id for r in picked] == [2, 4]


def test_to_book_carries_no_identifiers_no_year_and_no_existing_keys():
    book = to_book(_row(7, 300, 70, title="THE CITY IN HISTORY: Its Origins", keys=["OL1W"]))
    assert book.book_id == 70
    assert book.title == "THE CITY IN HISTORY: Its Origins"
    assert book.first_published_year is None
    assert book.isbn13 == [] and book.existing_ol_work_keys == []


def test_select_rows_holds_out_a_book_the_spike_saw_through_another_row():
    rows = [_row(1, 1, 10), _row(6, 250, 10), _row(7, 251, 11)]
    assert [r.list_item_id for r in select_rows(rows, skip_ranks_through=200)] == [7]


def test_load_rows_round_trips_authors_as_string_and_as_list(tmp_path):
    path = tmp_path / "rows.jsonl"
    path.write_text(
        '{"list_item_id":1,"md5_rank":1,"title":"A","authors":"X Y","book_id":5,'
        '"book_ol_work_keys":["OL1W"]}\n'
        '{"list_item_id":2,"md5_rank":2,"title":"B","authors":["P","Q"],"book_id":6,'
        '"book_ol_work_keys":[]}\n\n'
    )
    first, second = load_rows(path)
    assert first.authors == "X Y" and first.book_ol_work_keys == ["OL1W"]
    assert second.authors == ["P", "Q"]
