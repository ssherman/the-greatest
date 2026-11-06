# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    module GoodreadsRebuild
      class ResetBookTest < ActiveSupport::TestCase
        ASSOCIATIONS = %i[book_authors credits descriptions category_items images editions identifiers
          alternate_title_records series_books book_countries external_links].freeze

        setup do
          @book = ::Books::Book.create!(id: Cohort.post_import_range.first + 5_000, title: "Wrong Title")
          @author = ::Books::Author.create!(name: "Wrong Author")
        end

        test "clears every legacy-derived association and column" do
          fill(@book)

          result = ResetBook.call(book: @book)

          assert_predicate result, :success?
          book = ::Books::Book.find(@book.id)
          ASSOCIATIONS.each { |name| assert_equal 0, book.public_send(name).count, name.to_s }
          %i[description subtitle sort_title first_published_year original_language_id default_edition_id book_length
            page_range word_count amazon_enriched_at].each { |column| assert_nil book[column], column.to_s }
          assert_equal [], book.alternate_titles
          assert_equal 0, Identifier.where(identifiable_type: "Books::Edition", identifiable_id: @edition_id).count
        end

        test "keeps the book's id, slug, user list items, reviews and goodreads editions" do
          fill(@book)
          user = users(:regular_user)
          item = UserListItem.create!(user_list: user_lists(:regular_user_books_favorites), listable: @book, position: 1)
          review = Review.create!(user: user, reviewable: @book, rating: 4)
          gr = ::Books::GoodreadsEdition.create!(goodreads_book_id: 777, signature: "sig-777", title: "Wrong Title",
            primary_author: "X", book: @book)
          slug = @book.slug

          result = ResetBook.call(book: @book)

          book = result.data[:book]
          assert_equal [@book.id, slug, "Wrong Title"], [book.id, book.slug, book.title]
          assert_equal book.id, gr.reload.book_id
          assert UserListItem.exists?(item.id)
          assert Review.exists?(review.id)
        end

        test "refuses a trusted book" do
          trusted = ::Books::Book.create!(id: Cohort.post_import_range.first - 1, title: "Trusted")
          trusted.identifiers.create!(identifier_type: :books_work_asin, value: "B00KEEP123", source: :legacy)

          assert_raises(ArgumentError) { ResetBook.call(book: trusted) }
          assert_equal 1, trusted.identifiers.count
        end

        test "running it twice is harmless" do
          fill(@book)
          ResetBook.call(book: @book)

          result = ResetBook.call(book: @book.reload)

          assert_predicate result, :success?
          assert_equal [], result.data[:removed]["identifiers"]
        end

        test "returns an archive of the cleared identifiers, editions and links" do
          fill(@book)

          removed = ResetBook.call(book: @book).data[:removed]

          assert_includes removed["identifiers"], ["books_work_asin", "B00TEST123", "legacy"]
          edition = removed["editions"].first
          assert_equal "Wrong Edition", edition["title"]
          assert_includes edition["identifiers"], ["books_edition_asin", "B00EDIT456"]
          assert_includes edition["external_links"], ["https://www.amazon.com/dp/B00EDIT456", "amazon"]
          assert_includes removed["external_links"], ["https://www.amazon.com/dp/B00TEST123", "amazon"]
          assert_equal ["Wrong Title", "Wrong Subtitle", ["Wrong Author"]], removed.values_at("title", "subtitle", "author_names")
          assert_equal removed, JSON.parse(removed.to_json)
        end

        test "queues a search reindex" do
          assert_difference -> { SearchIndexRequest.where(parent: @book, action: :index_item).count }, 1 do
            ResetBook.call(book: @book)
          end
        end

        private

        def fill(book)
          book.book_authors.create!(author: @author, position: 1)
          book.credits.create!(author: @author, role: :translator)
          book.descriptions.create!(source: :manual, content: "legacy blurb")
          book.category_items.create!(category: categories(:books_fiction_genre))
          book.images.create!(primary: true) do |image|
            image.file.attach(io: StringIO.new("fake"), filename: "cover.jpg", content_type: "image/jpeg")
          end
          edition = book.editions.create!(title: "Wrong Edition")
          edition.identifiers.create!(identifier_type: :books_edition_asin, value: "B00EDIT456", source: :legacy)
          edition.external_links.create!(url: "https://www.amazon.com/dp/B00EDIT456", name: "Amazon", source: :amazon, link_category: :product_link)
          @edition_id = edition.id
          book.identifiers.create!(identifier_type: :books_work_asin, value: "B00TEST123", source: :legacy)
          ::AlternateTitle.create!(titleable: book, title: "Alt", source: :legacy, status: :kept)
          book.series_books.create!(series: books_series(:asoiaf))
          book.book_countries.create!(country: books_countries(:french))
          book.external_links.create!(url: "https://www.amazon.com/dp/B00TEST123", name: "Amazon", source: :amazon, link_category: :product_link)
          book.update_columns(description: "d", subtitle: "Wrong Subtitle", sort_title: "s", first_published_year: 1900,
            original_language_id: languages(:english).id, default_edition_id: edition.id, book_length: 3, page_range: "1-3",
            word_count: 10, amazon_enriched_at: Time.current, alternate_titles: ["Alt"])
        end
      end
    end
  end
end
