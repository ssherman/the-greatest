require "test_helper"

# == Schema Information
#
# Table name: books_books
#
#  id                   :bigint           not null, primary key
#  alternate_titles     :string           default([]), not null, is an Array
#  amazon_enriched_at   :datetime
#  book_kind            :integer          default(0), not null
#  book_length          :integer
#  description          :text
#  first_published_year :integer
#  page_range           :string
#  slug                 :string           not null
#  sort_title           :string
#  subtitle             :string
#  title                :string           not null
#  word_count           :integer
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
#  fk_rails_...  (default_edition_id => books_editions.id) ON DELETE => nullify
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

    test "a title that slugifies to a reserved word gets a non-reserved fallback slug" do
      book = Books::Book.create!(title: "Images")
      assert_equal "images-book", book.slug
      assert_not_includes Books::Book.friendly_id_config.reserved_words, book.slug
    end

    test "a second reserved-word title also falls back cleanly" do
      book = Books::Book.create!(title: "Users")
      assert_equal "users-book", book.slug
    end

    test "a non-reserved title still slugifies directly from the title" do
      book = Books::Book.create!(title: "A Perfectly Normal Book Title ABC")
      assert_equal "a-perfectly-normal-book-title-abc", book.slug
    end

    test "a duplicate non-reserved title keeps default conflict handling, not the reserved fallback" do
      Books::Book.create!(title: "Repeated Title XYZ")
      second = Books::Book.create!(title: "Repeated Title XYZ")
      assert_not_equal "repeated-title-xyz", second.slug
      assert_not_equal "repeated-title-xyz-book", second.slug
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

    test "book has work-level credits" do
      credit = Books::Credit.create!(author: books_authors(:tolstoy), creditable: books_books(:war_and_peace), role: :foreword)
      assert_includes books_books(:war_and_peace).credits, credit
    end

    test "destroying a book with default_edition and a work-level credit succeeds" do
      book = Books::Book.create!(title: "Ephemeral Book")
      edition = book.editions.create!
      book.update!(default_edition: edition)
      credit = Books::Credit.create!(author: books_authors(:tolstoy), creditable: book, role: :foreword)
      edition_id = edition.id
      credit_id = credit.id
      assert_nothing_raised { book.destroy }
      assert_not Books::Edition.exists?(edition_id)
      assert_not Books::Credit.exists?(credit_id)
    end

    test "as_indexed_json includes author_ids" do
      assert_includes books_books(:war_and_peace).as_indexed_json[:author_ids], books_authors(:tolstoy).id
    end

    test "release_year returns first_published_year" do
      book = ::Books::Book.new(first_published_year: 1869)
      assert_equal 1869, book.release_year
    end

    test "release_year is nil when first_published_year is nil" do
      assert_nil ::Books::Book.new(first_published_year: nil).release_year
    end

    # SearchIndexable concern tests
    test "should create search index request on create" do
      assert_difference "SearchIndexRequest.count", 1 do
        Books::Book.create!(title: "Test Search Book")
      end

      request = SearchIndexRequest.last
      assert_equal "Books::Book", request.parent_type
      assert request.index_item?
    end

    test "should create search index request on update" do
      book = books_books(:war_and_peace)

      assert_difference "SearchIndexRequest.count", 1 do
        book.update!(subtitle: "Updated Subtitle")
      end

      request = SearchIndexRequest.last
      assert_equal book, request.parent
      assert request.index_item?
    end

    test "should create search index request on destroy" do
      # of_mice_and_men, not crime_and_punishment: it carries no category_items,
      # so destroying it doesn't also cascade a reindex request per category
      # (see CategoryItem#queue_item_for_reindexing).
      book = books_books(:of_mice_and_men)

      assert_difference "SearchIndexRequest.count", 1 do
        book.destroy!
      end

      request = SearchIndexRequest.last
      assert_equal book.id, request.parent_id
      assert_equal "Books::Book", request.parent_type
      assert request.unindex_item?
    end

    test "book_length enum maps the six legacy bands to 0..5" do
      assert_equal({
        "very_short" => 0, "short" => 1, "medium" => 2,
        "moderate" => 3, "long" => 4, "very_long" => 5
      }, Books::Book.book_lengths)
    end

    test "derives book_length from page_range on create" do
      book = Books::Book.create!(title: "Derived From Pages", page_range: "200-400")

      assert_equal "medium", book.book_length
    end

    test "derives book_length from word_count when page_range is absent" do
      book = Books::Book.create!(title: "Derived From Words", word_count: 82_500)

      assert_equal "medium", book.book_length
    end

    test "does not overwrite an explicitly set book_length" do
      book = Books::Book.create!(title: "Explicit Length", page_range: "200-400", book_length: :very_long)

      assert_equal "very_long", book.book_length
    end

    test "leaves book_length nil when neither source is present" do
      book = Books::Book.create!(title: "No Length Source")

      assert_nil book.book_length
    end

    test "re-derives book_length when page_range changes and length is blank" do
      book = Books::Book.create!(title: "Late Page Range")
      assert_nil book.book_length

      book.update!(page_range: "600-700")

      assert_equal "long", book.book_length
    end

    test "an explicit book_length survives a later unrelated page_range update" do
      book = Books::Book.create!(title: "Explicit Then Updated", page_range: "1-10", book_length: :very_long)
      assert_equal "very_long", book.book_length

      book.update!(page_range: "200-400")

      assert_equal "very_long", book.book_length
    end

    test "does not derive book_length on save when neither source column changed" do
      book = Books::Book.create!(title: "Untouched Source")
      book.update_columns(page_range: "200-400", book_length: nil)

      book.update!(title: "Untouched Source, Renamed")

      assert_nil book.reload.book_length
    end

    test "as_indexed_json includes the saved-search filter fields" do
      book = books_books(:war_and_peace)
      json = book.as_indexed_json

      assert_equal book.first_published_year, json[:first_published_year]
      assert_equal book.original_language_id, json[:original_language_id]
      assert_kind_of Array, json[:country_ids]
      assert_includes [true, false], json[:ranked]
    end

    test "as_indexed_json category_ids excludes deleted and null-deleted categories, matching the active scope" do
      book = books_books(:war_and_peace)
      deleted_category = categories(:books_deleted_genre)
      CategoryItem.create!(category: deleted_category, item: book)
      null_deleted_category = ::Books::Category.create!(name: "Null Deleted Category")
      null_deleted_category.update_column(:deleted, nil)
      CategoryItem.create!(category: null_deleted_category, item: book)

      json = book.reload.as_indexed_json

      assert_equal book.categories.active.pluck(:id).sort, json[:category_ids].sort
      assert_not_includes json[:category_ids], deleted_category.id
      assert_not_includes json[:category_ids], null_deleted_category.id
    end

    test "as_indexed_json issues no queries beyond the model_includes preload" do
      books = Books::Book.where(id: books_books(:war_and_peace).id)
        .includes(Search::Books::BookIndex.model_includes)
        .to_a

      assert_queries_count(0) { books.first.as_indexed_json }
    end

    test "as_indexed_json emits book_length as its integer enum value, not the string key" do
      book = books_books(:war_and_peace)
      book.update!(book_length: :long)

      assert_equal 4, book.as_indexed_json[:book_length]
    end

    test "as_indexed_json emits a nil book_length rather than raising" do
      book = Books::Book.create!(title: "No Length At All")

      assert_nil book.as_indexed_json[:book_length]
    end

    test "as_indexed_json reports ranked_position from the primary ranking configuration" do
      book = books_books(:war_and_peace)
      RankedItem.create!(
        item: book,
        ranking_configuration: ranking_configurations(:books_global),
        rank: 7,
        score: 90.0
      )

      assert_equal 7, book.reload.as_indexed_json[:ranked_position]
    end

    test "as_indexed_json reports a nil ranked_position for an unranked book" do
      book = Books::Book.create!(title: "Never Ranked")

      assert_nil book.as_indexed_json[:ranked_position]
    end

    test "as_indexed_json ignores a rank from a non-primary ranking configuration" do
      book = books_books(:war_and_peace)
      RankedItem.create!(
        item: book,
        ranking_configuration: ranking_configurations(:books_user),
        rank: 3,
        score: 80.0
      )

      assert_nil book.reload.as_indexed_json[:ranked_position]
    end

    test "as_indexed_json splits categories by type" do
      book = books_books(:crime_and_punishment)
      json = book.as_indexed_json

      assert_equal [categories(:books_novels_genre).id], json[:genre_category_ids]
      assert_equal [categories(:books_politics_subject).id], json[:subject_category_ids]
      assert_equal [categories(:books_france_location).id], json[:location_category_ids]
    end

    test "as_indexed_json counts only the categories that score" do
      assert_equal 3, books_books(:crime_and_punishment).as_indexed_json[:similarity_category_count]
    end

    test "as_indexed_json excludes the book-type categories from the scoring count" do
      # Fiction/Nonfiction never contribute to the score numerator, so counting them
      # in the denominator divides a correctly-tagged book by more than an
      # identically-catalogued untagged one.
      book = books_books(:crime_and_punishment)
      before = book.as_indexed_json[:similarity_category_count]
      CategoryItem.create!(category: categories(:books_fiction_genre), item: book)
      book.reload

      assert_includes book.as_indexed_json[:genre_category_ids], categories(:books_fiction_genre).id
      assert_equal before, book.as_indexed_json[:similarity_category_count]
    end

    test "as_indexed_json still exposes category_ids" do
      # CategoryItem#item_supports_category_indexing? gates reindexing on this exact
      # key. Without it, editing a book's categories silently stops reindexing it.
      assert books_books(:crime_and_punishment).as_indexed_json.key?(:category_ids)
    end

    test "as_indexed_json excludes soft-deleted categories from the split fields" do
      book = books_books(:crime_and_punishment)
      categories(:books_novels_genre).update!(deleted: true)
      book.reload

      assert_empty book.as_indexed_json[:genre_category_ids]
      assert_equal 2, book.as_indexed_json[:similarity_category_count]
    end

    test "declares its correctable fields in display order" do
      assert_equal %w[title subtitle first_published_year page_range word_count alternate_titles description],
        ::Books::Book.correctable_field_names
    end

    test "does not expose the doomed description column as a column target" do
      assert_equal :description, ::Books::Book.correctable_fields["description"].target
    end

    test "clears book_length when page_range is corrected so it re-derives" do
      book = books_books(:war_and_peace)
      book.update!(page_range: "1200", book_length: :very_long)

      book.correction_applied(%w[page_range])
      assert_nil book.book_length
    end

    test "clears book_length when word_count is corrected" do
      book = books_books(:war_and_peace)
      book.update!(word_count: 500_000, book_length: :very_long)

      book.correction_applied(%w[word_count])
      assert_nil book.book_length
    end

    test "leaves book_length alone when an unrelated field is corrected" do
      book = books_books(:war_and_peace)
      book.update!(page_range: "1200", book_length: :very_long)

      book.correction_applied(%w[title])
      assert_equal "very_long", book.book_length
    end
  end
end
