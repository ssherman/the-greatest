# frozen_string_literal: true

require "test_helper"

module Services
  module Books
    class AmazonProductServiceTest < ActiveSupport::TestCase
      def setup
        @book = books_books(:war_and_peace)
      end

      test "fails when the book title is blank" do
        @book.title = ""

        result = AmazonProductService.call(book: @book)

        refute result[:success]
        assert_equal "Book title required", result[:error]
      end

      test "fails when the book has no authors" do
        @book.stubs(:authors).returns([])

        result = AmazonProductService.call(book: @book)

        refute result[:success]
        assert_equal "Book must have at least one author", result[:error]
      end

      test "fails loudly when the Amazon API errors" do
        ::Services::Amazon::Client.stubs(:search_items)
          .raises(::Services::Amazon::Client::Error, "Amazon API credentials not configured (AMAZON_PRODUCT_API_CRED_ID is missing)")

        result = AmazonProductService.call(book: @book)

        refute result[:success]
        assert_match(/Amazon API search failed/, result[:error])
      end

      test "the second search pass targets the Audible browse node" do
        captured = []
        ::Services::Amazon::Client.stubs(:search_items).with { |**kwargs|
          captured << kwargs
          true
        }.returns([])

        AmazonProductService.call(book: @book)

        assert_equal 2, captured.size
        assert_nil captured.first[:browse_node_id]
        assert_equal "18145289011", captured.last[:browse_node_id]
      end

      test "keywords combine the title and the author names" do
        captured = []
        ::Services::Amazon::Client.stubs(:search_items).with { |**kwargs|
          captured << kwargs
          true
        }.returns([])

        AmazonProductService.call(book: @book)

        assert_includes captured.first[:keywords], "War and Peace"
        assert_includes captured.first[:keywords], "Leo Tolstoy"
      end

      test "de-duplicates the same ASIN across both search passes" do
        ::Services::Amazon::Client.stubs(:search_items).returns([amazon_product])
        stub_ai_match
        stub_image

        assert_difference "::Books::Edition.count", 1 do
          AmazonProductService.call(book: @book)
        end
      end

      test "creates an edition and hangs the buy link off it" do
        ::Services::Amazon::Client.stubs(:search_items).returns([amazon_product])
        stub_ai_match
        stub_image

        result = AmazonProductService.call(book: @book)

        assert result[:success]
        edition = ::Books::Edition.joins(:identifiers)
          .where(identifiers: {identifier_type: Identifier.identifier_types[:books_edition_asin], value: "1400079985"})
          .first
        assert edition

        link = edition.external_links.find_by(source: :amazon)
        assert link
        assert_equal "https://amazon.com/dp/1400079985", link.url
        assert_equal "product_link", link.link_category
      end

      test "gives the book a cover when it has none" do
        @book.images.destroy_all
        ::Services::Amazon::Client.stubs(:search_items).returns([amazon_product])
        stub_ai_match
        stub_image

        AmazonProductService.call(book: @book)

        assert @book.reload.images.where(primary: true).exists?
      end

      test "leaves an existing book cover alone" do
        @book.images.create!(primary: true) do |image|
          image.file.attach(io: StringIO.new("existing"), filename: "existing.jpg", content_type: "image/jpeg")
        end
        ::Services::Amazon::Client.stubs(:search_items).returns([amazon_product])
        stub_ai_match
        stub_image

        AmazonProductService.call(book: @book)

        assert_equal 1, @book.reload.images.where(primary: true).count
      end

      test "creates the book level affiliate link from the physical edition" do
        ::Services::Amazon::Client.stubs(:search_items).returns([amazon_product])
        stub_ai_match
        stub_image

        AmazonProductService.call(book: @book)

        assert_equal "https://amazon.com/dp/1400079985",
          @book.external_links.find_by(source: :amazon)&.url
      end

      test "does not build a book level link from an audiobook only match" do
        audiobook = amazon_product.deep_merge(
          "itemInfo" => {"classifications" => {"binding" => {"displayValue" => "Audible Audiobook"}}}
        )
        ::Services::Amazon::Client.stubs(:search_items).returns([audiobook])
        stub_ai_match
        stub_image

        AmazonProductService.call(book: @book)

        assert_nil @book.external_links.find_by(source: :amazon)
      end

      test "surfaces AI failures" do
        ::Services::Amazon::Client.stubs(:search_items).returns([amazon_product])
        ai_result = stub(success?: false, error: "AI processing failed", data: nil)
        ::Services::Ai::Tasks::Books::AmazonBookMatchTask.any_instance.stubs(:call).returns(ai_result)

        result = AmazonProductService.call(book: @book)

        refute result[:success]
        assert_equal "AI validation failed: AI processing failed", result[:error]
      end

      # A rank-winning edition with no cover must not leave the book coverless
      # when a lower-ranked physical edition has one.
      test "takes the book cover from a lower ranked physical edition when the best has none" do
        @book.images.destroy_all
        coverless = amazon_product.deep_merge("browseNodeInfo" => {"websiteSalesRank" => {"salesRank" => 1}})
        coverless.delete("images")
        withcover = amazon_product.deep_merge(
          "asin" => "0140449175",
          "detailPageURL" => "https://amazon.com/dp/0140449175",
          "browseNodeInfo" => {"websiteSalesRank" => {"salesRank" => 900}},
          "images" => {"primary" => {"large" => {"url" => "https://images.amazon.com/fallback.jpg"}}}
        )
        ::Services::Amazon::Client.stubs(:search_items).returns([coverless, withcover])
        stub_ai_match_for(%w[1400079985 0140449175])
        stub_request(:get, "https://images.amazon.com/fallback.jpg")
          .to_return(status: 200, body: "fake image data", headers: {"Content-Type" => "image/jpeg"})

        AmazonProductService.call(book: @book)

        # Two real downloads of the same URL are expected here: persist_match
        # attaches it to the withcover edition's own cover, then
        # attach_book_cover attaches it again to the book's.
        assert_requested :get, "https://images.amazon.com/fallback.jpg", times: 2
        assert @book.reload.images.where(primary: true).exists?
      end

      private

      def amazon_product
        {
          "asin" => "1400079985",
          "detailPageURL" => "https://amazon.com/dp/1400079985",
          "itemInfo" => {
            "title" => {"displayValue" => "War and Peace (Vintage Classics)"},
            "byLineInfo" => {"manufacturer" => {"displayValue" => "Vintage"}},
            "classifications" => {"binding" => {"displayValue" => "Paperback"}},
            "contentInfo" => {
              "pagesCount" => {"displayValue" => 1296},
              "publicationDate" => {"displayValue" => "2008-10-14T00:00:01Z"}
            }
          },
          "images" => {"primary" => {"large" => {"url" => "https://images.amazon.com/wp.jpg"}}},
          "browseNodeInfo" => {"websiteSalesRank" => {"salesRank" => 4211}},
          "offersV2" => {"listings" => [
            {"condition" => {"value" => "New"}, "price" => {"money" => {"amount" => 14.99}}}
          ]}
        }
      end

      def stub_ai_match
        ai_result = stub(
          success?: true,
          data: {matching_results: [
            {asin: "1400079985", title: "War and Peace", author: "Leo Tolstoy", explanation: "Same work"}
          ]}
        )
        ::Services::Ai::Tasks::Books::AmazonBookMatchTask.any_instance.stubs(:call).returns(ai_result)
      end

      def stub_ai_match_for(asins)
        matching_results = asins.map do |asin|
          {asin: asin, title: "War and Peace", author: "Leo Tolstoy", explanation: "Same work"}
        end
        ai_result = stub(success?: true, data: {matching_results: matching_results})
        ::Services::Ai::Tasks::Books::AmazonBookMatchTask.any_instance.stubs(:call).returns(ai_result)
      end

      def stub_image
        stub_request(:get, "https://images.amazon.com/wp.jpg")
          .to_return(status: 200, body: "fake image data", headers: {"Content-Type" => "image/jpeg"})
      end
    end
  end
end
