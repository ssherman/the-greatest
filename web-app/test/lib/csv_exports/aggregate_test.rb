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

    test "joins several names with a comma and honours the order clause" do
      book = books_books(:war_and_peace)
      scope = ::CategoryItem.joins(:category).where(item_type: "Books::Book", item_id: [book.id],
        categories: {deleted: false, category_type: ::Category.category_types[:genre]})

      ascending = Aggregate.names(scope, group_by: "category_items.item_id", name: "categories.name", order: "categories.name")
      descending = Aggregate.names(scope, group_by: "category_items.item_id", name: "categories.name", order: "categories.name DESC")

      assert_equal({book.id => "Classics, Novels"}, ascending)
      assert_equal({book.id => "Novels, Classics"}, descending)
    end

    test "answers every owner in the batch" do
      ids = [books_books(:war_and_peace).id, books_books(:got).id]

      names = Aggregate.names(::Books::BookCountry.joins(:country).where(book_id: ids),
        group_by: "books_book_countries.book_id", name: "books_countries.name")

      assert_equal ids.sort, names.keys.sort
    end
  end
end
