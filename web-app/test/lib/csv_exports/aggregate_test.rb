# frozen_string_literal: true

require "test_helper"

module CsvExports
  class AggregateTest < ActiveSupport::TestCase
    test "joins names per owner in the requested order" do
      book = books_books(:war_and_peace)
      names = Aggregate.names(
        ::Books::BookCountry.joins(:country).where(book_id: [book.id]),
        group_by: "books_book_countries.book_id",
        name: "books_countries.name",
        order: "books_countries.name"
      )

      assert_equal({book.id => "French"}, names)
    end

    test "an owner with nothing to aggregate is simply absent" do
      names = Aggregate.names(
        ::Books::BookCountry.joins(:country).where(book_id: [-1]),
        group_by: "books_book_countries.book_id",
        name: "books_countries.name"
      )

      assert_equal({}, names)
    end
  end
end
