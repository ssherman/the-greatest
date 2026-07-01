require "test_helper"

# == Schema Information
#
# Table name: books_books
#
#  id                   :bigint           not null, primary key
#  alternate_titles     :string           default([]), not null, is an Array
#  book_kind            :integer          default("standalone"), not null
#  description          :text
#  first_published_year :integer
#  slug                 :string           not null
#  sort_title           :string
#  subtitle             :string
#  title                :string           not null
#  created_at           :datetime         not null
#  updated_at           :datetime         not null
#  default_edition_id   :bigint
#  original_language_id :bigint
#
# Indexes
#
#  index_books_books_on_alternate_titles      (alternate_titles) USING gin
#  index_books_books_on_book_kind             (book_kind)
#  index_books_books_on_default_edition_id    (default_edition_id)
#  index_books_books_on_first_published_year  (first_published_year)
#  index_books_books_on_original_language_id  (original_language_id)
#  index_books_books_on_slug                  (slug) UNIQUE
#
# Foreign Keys
#
#  fk_rails_...  (default_edition_id => books_editions.id)
#  fk_rails_...  (original_language_id => languages.id)
#
module Books
  class BookTest < ActiveSupport::TestCase
    test "is valid with a title" do
      assert_predicate Books::Book.new(title: "Ulysses"), :valid?
    end

    test "requires a title" do
      book = Books::Book.new
      assert_not book.valid?
      assert_includes book.errors[:title], "can't be blank"
    end

    test "generates a slug from the title" do
      book = Books::Book.create!(title: "Don Quixote")
      assert_equal "don-quixote", book.slug
    end

    test "defaults to standalone kind" do
      assert_predicate Books::Book.new(title: "X"), :standalone?
    end

    test "selectable scope excludes collections" do
      assert_includes Books::Book.selectable, books_books(:war_and_peace)
      assert_not_includes Books::Book.selectable, books_books(:combo_steinbeck)
    end

    test "belongs to an original language" do
      assert_equal languages(:russian), books_books(:war_and_peace).original_language
    end

    test "as_indexed_json includes title, alternate_titles and author names" do
      json = books_books(:war_and_peace).as_indexed_json
      assert_equal "War and Peace", json[:title]
      assert_kind_of Array, json[:alternate_titles]
      assert_kind_of Array, json[:author_names]
    end
  end
end
