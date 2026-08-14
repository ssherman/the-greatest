require "test_helper"

class ReviewableTest < ActiveSupport::TestCase
  # A stand-in reviewable that includes the concern but implements none of it,
  # so the contract's own failure mode is pinned rather than assumed.
  class UnimplementedReviewable < ApplicationRecord
    self.table_name = "books_books"
    include Reviewable
  end

  test "the contract raises until a reviewable implements it" do
    %i[review_row_includes review_title_order ranking_configuration_class].each do |method|
      assert_raises(NotImplementedError) { UnimplementedReviewable.public_send(method) }
    end
    assert_raises(NotImplementedError) { UnimplementedReviewable.review_text_search(Review.all, "x") }
    assert_raises(NotImplementedError) { UnimplementedReviewable.review_creator_names(UnimplementedReviewable.new) }
    assert_raises(NotImplementedError) { UnimplementedReviewable.review_public_path(UnimplementedReviewable.new) }
  end

  test "Books::Book implements the whole contract" do
    assert_equal [{primary_image: {file_attachment: :blob}}, {book_authors: :author}], ::Books::Book.review_row_includes
    assert_equal "COALESCE(books_books.sort_title, books_books.title)", ::Books::Book.review_title_order
    assert_equal ::Books::RankingConfiguration, ::Books::Book.ranking_configuration_class

    book = books_books(:war_and_peace)
    assert_equal ["Leo Tolstoy"], ::Books::Book.review_creator_names(book)
    assert_equal Rails.application.routes.url_helpers.book_path(book.slug), ::Books::Book.review_public_path(book)
  end

  test "review_creator_names preserves book_authors' position order" do
    book = books_books(:war_and_peace)
    second_author = ::Books::Author.create!(name: "A Second Author", kind: :organization)
    ::Books::BookAuthor.create!(book: book, author: second_author, position: 0)

    # position 0 sorts before the fixture author's position 1, so a correct
    # implementation puts the new author first -- pinning that this delegates
    # to book_authors' own ordering rather than an unordered `authors` walk.
    assert_equal ["A Second Author", "Leo Tolstoy"], ::Books::Book.review_creator_names(book)
  end

  test "the concern supplies the review associations" do
    book = books_books(:war_and_peace)
    assert_equal 3, book.reviews.count
    assert book.review_summary.present?
  end

  test "review_text_search matches a book title" do
    scope = Review.joins("INNER JOIN books_books ON books_books.id = reviews.reviewable_id")
      .where(reviewable_type: "Books::Book")
    assert_includes ::Books::Book.review_text_search(scope, "war and peace").map(&:reviewable_id),
      books_books(:war_and_peace).id
  end

  test "review_text_search matches an author name without duplicating rows" do
    book = books_books(:war_and_peace)
    author_name = book.authors.first.name
    # A second author whose name ALSO matches the search term is what makes a plain
    # INNER JOIN multiply: with only one matching author (the fixture default), a
    # join filtered by WHERE happens to collapse back down to one row per review, so
    # it would pass here even with the join bug this test exists to catch. Two
    # matching authors on one book makes a join return two joined rows per review
    # (6 total for 3 reviews) where EXISTS still returns one (3 total).
    second_author = ::Books::Author.create!(name: "#{author_name} Estate", kind: :organization)
    ::Books::BookAuthor.create!(book: book, author: second_author, position: 2)

    scope = Review.joins("INNER JOIN books_books ON books_books.id = reviews.reviewable_id")
      .where(reviewable_type: "Books::Book", reviewable_id: book.id)
    results = ::Books::Book.review_text_search(scope, author_name).to_a
    assert_equal results.size, results.map(&:id).uniq.size, "author join must not multiply rows"
    assert_equal 3, results.size
  end

  test "review_text_search escapes LIKE wildcards in the term" do
    scope = Review.joins("INNER JOIN books_books ON books_books.id = reviews.reviewable_id")
      .where(reviewable_type: "Books::Book")
    assert_empty ::Books::Book.review_text_search(scope, "%").to_a
  end
end
