require "test_helper"

module Books
  class ListTest < ActiveSupport::TestCase
    # books_countries(:french) carries labels: [western]
    # books_countries(:japanese) carries labels: [asian]
    # books_books(:crime_and_punishment) has no books_book_countries row at all
    def setup
      @list = ::Books::List.create!(name: "Western Percentage Test List", status: :approved)
    end

    def add_book(book, position)
      ListItem.create!(list: @list, listable: book, position: position)
    end

    test "returns 100.0 when every book is western" do
      add_book(books_books(:war_and_peace), 1)
      add_book(books_books(:got), 2)

      assert_in_delta 100.0, @list.percentage_western, 0.001
    end

    test "returns the western share rounded to two places" do
      add_book(books_books(:war_and_peace), 1)   # french -> western
      add_book(books_books(:got), 2)             # french -> western
      add_book(books_books(:of_mice_and_men), 3) # japanese -> not western

      # 2 of 3 = 66.666... -> 66.67
      assert_in_delta 66.67, @list.percentage_western, 0.001
    end

    test "counts a book with no country as not western" do
      add_book(books_books(:war_and_peace), 1)         # western
      add_book(books_books(:crime_and_punishment), 2)  # no country row

      assert_in_delta 50.0, @list.percentage_western, 0.001
    end

    test "returns 0.0 when no book is western" do
      add_book(books_books(:of_mice_and_men), 1)

      assert_in_delta 0.0, @list.percentage_western, 0.001
    end

    test "returns nil when the list has no items" do
      assert_nil @list.percentage_western
    end

    test "ignores items with no resolved book" do
      add_book(books_books(:war_and_peace), 1)
      ListItem.create!(list: @list, listable_type: "Books::Book", listable_id: nil, position: 2)

      # The unresolved item is excluded from both numerator and denominator.
      assert_in_delta 100.0, @list.percentage_western, 0.001
    end
  end
end
