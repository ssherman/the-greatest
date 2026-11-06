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

      test "a Goodreads ISBN is searched first, ahead of the keyword sets" do
        @book.identifiers.where(identifier_type: :books_work_isbn13).delete_all
        @book.identifiers.create!(identifier_type: :books_work_isbn13, value: "9780140447934", source: :goodreads)
        captured = capture_searches

        AmazonProductService.call(book: @book)

        assert_equal 3, captured.size
        assert_equal({keywords: "9780140447934", search_index: "Books"}, captured.first.slice(:keywords, :search_index))
        assert_nil captured.first[:browse_node_id]
        assert_nil captured.second[:keywords][/9780140447934/]
      end

      test "with an Open Library and a Goodreads ISBN the higher trust rank is searched" do
        @book.identifiers.where(identifier_type: :books_work_isbn13).delete_all
        @book.identifiers.create!(identifier_type: :books_work_isbn13, value: "9780140447934", source: :goodreads)
        @book.identifiers.create!(identifier_type: :books_work_isbn13, value: "9781400079988", source: :open_library)
        captured = capture_searches

        AmazonProductService.call(book: @book)

        assert_equal 3, captured.size
        assert_equal "9781400079988", captured.first[:keywords]
      end

      test "a legacy ISBN alone adds no ISBN search" do
        @book.identifiers.where(identifier_type: :books_work_isbn13).delete_all
        @book.identifiers.create!(identifier_type: :books_work_isbn13, value: "9780140447934", source: :legacy)
        captured = capture_searches

        AmazonProductService.call(book: @book)

        assert_equal 2, captured.size
        assert_nil captured.first[:keywords][/9780140447934/]
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
        # Both passes return the same product. The AI task must see it once.
        ::Services::Amazon::Client.stubs(:search_items).returns([amazon_product])

        captured = nil
        ::Services::Ai::Tasks::Books::AmazonBookMatchTask.stubs(:new).with { |**kwargs|
          captured = kwargs[:search_results]
          true
        }.returns(stub(call: stub(success?: true, data: {matching_results: []})))

        AmazonProductService.call(book: @book)

        assert_equal 1, captured.size
        assert_equal "1400079985", captured.first["asin"]
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

      # One unusable product must not cost the book its other matches.
      test "skips a product that fails to persist and keeps the rest" do
        second = amazon_product.deep_merge(
          "asin" => "0140449175",
          "detailPageURL" => "https://amazon.com/dp/0140449175"
        )
        ::Services::Amazon::Client.stubs(:search_items).returns([amazon_product, second])
        stub_ai_match_for(%w[1400079985 0140449175])
        stub_image

        ::Services::Books::AmazonEditionUpserter
          .stubs(:call)
          .with(has_entries(product: has_entries("asin" => "1400079985")))
          .raises(ActiveRecord::RecordInvalid.new(::Books::Edition.new))
        ::Services::Books::AmazonEditionUpserter
          .stubs(:call)
          .with(has_entries(product: has_entries("asin" => "0140449175")))
          .returns(::Services::Books::AmazonEditionUpserter::Result.new(
            edition: @book.editions.create!(edition_type: :standard, book_binding: :paperback, popularity: 10),
            created: true
          ))

        result = AmazonProductService.call(book: @book)

        assert result[:success]
        # "products" counts every AI-validated match (2); "links created" counts
        # only the ones that actually persisted (1) -- the raising ASIN is
        # skipped, not silently dropped from the count.
        assert_match(/2 products, 1 links created/, result[:data])
      end

      # upsert_external_link alone dedups by URL, so a byte-identical re-run
      # would look idempotent even with the guard deleted. The guard actually
      # earns its keep when a LATER run's best-selling physical edition is a
      # different product: without it, attach_book_affiliate_link would point
      # the book at the new product's URL and add a second amazon link
      # instead of leaving the first one alone.
      test "leaves an existing book level amazon link alone on a re-run" do
        ::Services::Amazon::Client.stubs(:search_items).returns([amazon_product])
        stub_ai_match
        stub_image
        AmazonProductService.call(book: @book)
        original = @book.external_links.find_by(source: :amazon)
        assert original
        assert_equal "https://amazon.com/dp/1400079985", original.url

        better_ranked = amazon_product.deep_merge(
          "asin" => "0140449175",
          "detailPageURL" => "https://amazon.com/dp/0140449175",
          "browseNodeInfo" => {"websiteSalesRank" => {"salesRank" => 1}}
        )
        ::Services::Amazon::Client.stubs(:search_items).returns([amazon_product, better_ranked])
        stub_ai_match_for(%w[1400079985 0140449175])

        assert_no_difference -> { @book.external_links.where(source: :amazon).count } do
          AmazonProductService.call(book: @book)
        end

        assert_equal original.id, @book.external_links.find_by(source: :amazon).id
        assert_equal "https://amazon.com/dp/1400079985", @book.external_links.find_by(source: :amazon).url
      end

      # Music's after_persist only attaches an image, which rescues internally.
      # Books also creates a book-level link, which does not -- an editions-only
      # success must not be turned into a failure (and 25 Sidekiq retries of
      # already-persisted work) by a bad book-level link write.
      test "a failing book-level affiliate link does not fail an otherwise successful run" do
        ::Services::Amazon::Client.stubs(:search_items).returns([amazon_product])
        stub_ai_match
        stub_image

        AmazonProductService.any_instance.stubs(:upsert_external_link).returns(nil)
        AmazonProductService.any_instance.stubs(:upsert_external_link)
          .with(has_entries(parent: @book))
          .raises(StandardError, "boom")

        result = AmazonProductService.call(book: @book)

        assert result[:success]
        assert_match(/Failed to create book-level Amazon link: boom/, result[:errors].join(" "))
      end

      test "an AI-accepted box set writes no edition, link or cover" do
        boxed = amazon_product.deep_merge("itemInfo" => {"title" => {"displayValue" => "War and Peace (Boxed Set)"}})
        ::Services::Amazon::Client.stubs(:search_items).returns([boxed])
        stub_ai_match
        stub_image

        assert_no_difference ["::Books::Edition.count", "ExternalLink.count", "Image.count"] do
          AmazonProductService.call(book: @book)
        end
      end

      test "a single-book series marker still becomes an edition" do
        marker = amazon_product.deep_merge("itemInfo" => {"title" => {"displayValue" => "War and Peace (Tolstoy Trilogy, Book 1)"}})
        ::Services::Amazon::Client.stubs(:search_items).returns([marker])
        stub_ai_match
        stub_image

        assert_difference "::Books::Edition.count", 1 do
          AmazonProductService.call(book: @book)
        end
      end

      test "a single-book series marker creates its edition and writes the book-level identifiers" do
        marker = with_identifiers.deep_merge("itemInfo" => {"title" => {"displayValue" => "War and Peace (Tolstoy Trilogy, Book 1)"}})
        ::Services::Amazon::Client.stubs(:search_items).returns([marker])
        stub_ai_match
        stub_image

        assert_difference "::Books::Edition.count", 1 do
          AmazonProductService.call(book: @book)
        end
        assert @book.identifiers.exists?(identifier_type: :books_work_isbn13, value: "9781400079988", source: :amazon)
      end

      test "an exact match also writes its identifiers to the book" do
        ::Services::Amazon::Client.stubs(:search_items).returns([with_identifiers])
        stub_ai_match
        stub_image

        AmazonProductService.call(book: @book)

        assert @book.identifiers.exists?(identifier_type: :books_work_isbn13, value: "9781400079988", source: :amazon)
        assert @book.identifiers.exists?(identifier_type: :books_work_asin, value: "1400079985", source: :amazon)
      end

      test "an accepted product that is not exactly the book still becomes an edition but writes no book identifiers" do
        no_author = with_identifiers.deep_merge("itemInfo" => {"byLineInfo" => {"contributors" => []}})
        ::Services::Amazon::Client.stubs(:search_items).returns([no_author])
        stub_ai_match
        stub_image

        assert_difference "::Books::Edition.count", 1 do
          AmazonProductService.call(book: @book)
        end
        refute @book.identifiers.exists?(source: :amazon)
      end

      test "a failure writing book identifiers is reported but the run still succeeds" do
        ::Services::Amazon::Client.stubs(:search_items).returns([with_identifiers])
        stub_ai_match
        stub_image
        ::Services::Books::AmazonBookIdentifiers.stubs(:call).raises(StandardError, "boom")

        result = AmazonProductService.call(book: @book)

        assert result[:success]
        assert_equal 1, @book.editions.joins(:identifiers).where(identifiers: {value: "1400079985"}).count
        assert(result[:errors].any? { |e| e.include?("boom") })
      end

      private

      def capture_searches
        captured = []
        ::Services::Amazon::Client.stubs(:search_items).with { |**kwargs|
          captured << kwargs
          true
        }.returns([])
        captured
      end

      def with_identifiers
        amazon_product.deep_merge("itemInfo" => {
          "externalIds" => {"isbns" => {"displayValues" => ["9781400079988"]}},
          "byLineInfo" => {"contributors" => [{"name" => "Leo Tolstoy", "role" => "Author"}]}
        })
      end

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
