require "test_helper"

# == Schema Information
#
# Table name: books_editions
#
#  id               :bigint           not null, primary key
#  book_binding     :integer
#  edition_type     :integer          default("standard"), not null
#  metadata         :jsonb            not null
#  page_count       :integer
#  popularity       :integer
#  publication_year :integer
#  publisher_name   :string
#  subtitle         :string
#  title            :string
#  volume_number    :integer
#  created_at       :datetime         not null
#  updated_at       :datetime         not null
#  book_id          :bigint           not null
#  language_id      :bigint
#
# Indexes
#
#  index_books_editions_on_book_id        (book_id)
#  index_books_editions_on_edition_type   (edition_type)
#  index_books_editions_on_language_id    (language_id)
#  index_books_editions_on_volume_number  (volume_number)
#
# Foreign Keys
#
#  fk_rails_...  (book_id => books_books.id)
#  fk_rails_...  (language_id => languages.id)
#
module Books
  class EditionTest < ActiveSupport::TestCase
    test "is valid with a book" do
      assert_predicate Books::Edition.new(book: books_books(:war_and_peace)), :valid?
    end

    test "requires a book" do
      edition = Books::Edition.new
      assert_not edition.valid?
      assert_includes edition.errors[:book], "must exist"
    end

    test "defaults to standard edition_type" do
      assert_predicate Books::Edition.new(book: books_books(:war_and_peace)), :edition_type_standard?
    end

    test "belongs to a language" do
      assert_equal languages(:english), books_editions(:wp_maude).language
    end

    test "volume editions carry a volume_number" do
      assert_equal 1, books_editions(:wp_volume_one).volume_number
    end

    test "book has many editions" do
      assert_includes books_books(:war_and_peace).editions, books_editions(:wp_maude)
    end

    test "complete scope excludes volume editions" do
      assert_includes Books::Edition.complete, books_editions(:wp_maude)
      assert_not_includes Books::Edition.complete, books_editions(:wp_volume_one)
    end

    test "by_binding scope filters" do
      assert_includes Books::Edition.by_binding(:paperback), books_editions(:wp_maude)
    end
  end
end
