# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class AmazonEditionUpserterTest < ActiveSupport::TestCase
      def setup
        @book = books_books(:war_and_peace)
      end

      def product(overrides = {})
        {
          "asin" => "1400079985",
          "detailPageURL" => "https://amazon.com/dp/1400079985",
          "itemInfo" => {
            "title" => {"displayValue" => "War and Peace: A Novel (Vintage Classics)"},
            "byLineInfo" => {"manufacturer" => {"displayValue" => "Vintage"}},
            "classifications" => {"binding" => {"displayValue" => "Paperback"}},
            "contentInfo" => {
              "pagesCount" => {"displayValue" => 1296},
              "publicationDate" => {"displayValue" => "2008-10-14T00:00:01Z"},
              "languages" => {"displayValues" => [
                {"displayValue" => "English", "type" => "Published"},
                {"displayValue" => "Russian", "type" => "Original Language"}
              ]}
            },
            "externalIds" => {
              "isbns" => {"displayValues" => ["1400079985"]},
              "eans" => {"displayValues" => ["9781400079988"]}
            }
          },
          "browseNodeInfo" => {"websiteSalesRank" => {"salesRank" => 4211}}
        }.deep_merge(overrides)
      end

      test "creates a new edition for an unseen ASIN" do
        assert_difference "::Books::Edition.count", 1 do
          result = AmazonEditionUpserter.call(book: @book, product: product)

          assert result.created
          assert_equal @book, result.edition.book
        end
      end

      test "maps the descriptive fields off the product" do
        edition = AmazonEditionUpserter.call(book: @book, product: product).edition

        assert_equal "War and Peace", edition.title
        assert_equal "A Novel", edition.subtitle
        assert_equal "paperback", edition.book_binding
        assert_equal "Vintage", edition.publisher_name
        assert_equal 2008, edition.publication_year
        assert_equal 1296, edition.page_count
        assert_equal 4211, edition.popularity
        assert_equal languages(:english), edition.language
      end

      test "writes edition level asin isbn and ean identifiers" do
        edition = AmazonEditionUpserter.call(book: @book, product: product).edition

        assert_equal ["1400079985"], edition.identifiers.where(identifier_type: :books_edition_asin).pluck(:value)
        assert_equal ["1400079985"], edition.identifiers.where(identifier_type: :books_edition_isbn10).pluck(:value)
        assert_equal ["9781400079988"], edition.identifiers.where(identifier_type: :books_edition_ean13).pluck(:value)
      end

      test "finds the existing edition again by ASIN instead of duplicating it" do
        first = AmazonEditionUpserter.call(book: @book, product: product).edition

        assert_no_difference "::Books::Edition.count" do
          second = AmazonEditionUpserter.call(book: @book, product: product)

          refute second.created
          assert_equal first.id, second.edition.id
        end
      end

      # The fixture ISBN is 10 characters, so this resolves through the EAN-13
      # fallback -- ISBN-10 is deliberately not a lookup key.
      test "finds the existing edition by EAN when the ASIN changed" do
        first = AmazonEditionUpserter.call(book: @book, product: product).edition
        reissued = product("asin" => "9999999999")

        assert_no_difference "::Books::Edition.count" do
          assert_equal first.id, AmazonEditionUpserter.call(book: @book, product: reissued).edition.id
        end
      end

      test "does not match an edition belonging to a different book" do
        other_book = books_books(:crime_and_punishment)
        AmazonEditionUpserter.call(book: @book, product: product)

        assert_difference "::Books::Edition.count", 1 do
          AmazonEditionUpserter.call(book: other_book, product: product)
        end
      end

      test "always refreshes popularity and metadata on an existing edition" do
        edition = AmazonEditionUpserter.call(book: @book, product: product).edition

        AmazonEditionUpserter.call(
          book: @book,
          product: product("browseNodeInfo" => {"websiteSalesRank" => {"salesRank" => 12}})
        )

        edition.reload
        assert_equal 12, edition.popularity
        assert_equal "1400079985", edition.metadata.dig("amazon", "asin")
      end

      test "never overwrites a populated descriptive field" do
        edition = AmazonEditionUpserter.call(book: @book, product: product).edition
        edition.update!(title: "Hand Corrected Title", publisher_name: "Corrected Publisher")

        AmazonEditionUpserter.call(book: @book, product: product)

        edition.reload
        assert_equal "Hand Corrected Title", edition.title
        assert_equal "Corrected Publisher", edition.publisher_name
      end

      test "fills a descriptive field that is blank on an existing edition" do
        edition = @book.editions.create!(edition_type: :standard, title: "Existing")
        edition.identifiers.create!(identifier_type: :books_edition_asin, value: "1400079985")

        AmazonEditionUpserter.call(book: @book, product: product)

        edition.reload
        assert_equal "Existing", edition.title
        assert_equal 1296, edition.page_count
        assert_equal "Vintage", edition.publisher_name
      end

      test "maps an unrecognised binding to other rather than raising" do
        edition = AmazonEditionUpserter.call(
          book: @book,
          product: product("itemInfo" => {"classifications" => {"binding" => {"displayValue" => "Papyrus Scroll"}}})
        ).edition

        assert_equal "other", edition.book_binding
      end

      test "leaves language nil when Amazon names one we do not have" do
        edition = AmazonEditionUpserter.call(
          book: @book,
          product: product("itemInfo" => {"contentInfo" => {"languages" => {"displayValues" => [
            {"displayValue" => "Esperanto", "type" => "Published"}
          ]}}})
        ).edition

        assert_nil edition.language_id
      end

      test "does not create a Language row from Amazon data" do
        assert_no_difference "Language.count" do
          AmazonEditionUpserter.call(
            book: @book,
            product: product("itemInfo" => {"contentInfo" => {"languages" => {"displayValues" => [
              {"displayValue" => "Esperanto", "type" => "Published"}
            ]}}})
          )
        end
      end
    end
  end
end
