require "test_helper"

module Books
  class BookRelationshipTest < ActiveSupport::TestCase
    test "a collection contains component works" do
      rel = books_book_relationships(:combo_contains_omam)
      assert_equal books_books(:combo_steinbeck), rel.book
      assert_equal books_books(:of_mice_and_men), rel.related_book
      assert_predicate rel, :relation_type_contains?
    end

    test "rejects self-reference" do
      rel = Books::BookRelationship.new(book: books_books(:war_and_peace), related_book: books_books(:war_and_peace), relation_type: :contains)
      assert_not rel.valid?
      assert_includes rel.errors[:related_book_id], "cannot relate a book to itself"
    end

    test "is unique per book/related/type" do
      dup = Books::BookRelationship.new(book: books_books(:combo_steinbeck), related_book: books_books(:of_mice_and_men), relation_type: :contains)
      assert_not dup.valid?
      assert_includes dup.errors[:book_id], "has already been taken"
    end

    test "book exposes related_books" do
      assert_includes books_books(:combo_steinbeck).related_books, books_books(:of_mice_and_men)
    end

    test "containing scope filters" do
      assert_includes Books::BookRelationship.containing, books_book_relationships(:combo_contains_omam)
    end
  end
end
