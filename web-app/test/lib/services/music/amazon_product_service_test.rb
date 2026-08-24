# frozen_string_literal: true

require "test_helper"

module Services
  module Music
    class AmazonProductServiceTest < ActiveSupport::TestCase
      def setup
        @album = music_albums(:dark_side_of_the_moon)
      end

      test "call returns failure when album title is blank" do
        @album.title = ""

        result = AmazonProductService.call(album: @album)

        refute result[:success]
        assert_equal "Album title required", result[:error]
      end

      test "call returns failure when album has no artists" do
        @album.stubs(:artists).returns([])

        result = AmazonProductService.call(album: @album)

        refute result[:success]
        assert_equal "Album must have at least one artist", result[:error]
      end

      test "call returns failure when Amazon API credentials are missing" do
        ::Services::Amazon::Client.stubs(:search_items)
          .raises(::Services::Amazon::Client::Error, "Amazon API credentials not configured (AMAZON_PRODUCT_API_CRED_ID is missing)")

        result = AmazonProductService.call(album: @album)

        refute result[:success]
        assert_match(/Amazon API search failed/, result[:error])
        assert_match(/credentials not configured/, result[:error])
      end

      test "call returns success when no matching products found after AI validation" do
        mock_amazon_api
        mock_ai_validation([])

        result = AmazonProductService.call(album: @album)

        assert result[:success]
        assert_equal "No matching products found", result[:data]
      end

      test "call creates external links for validated products" do
        mock_amazon_api

        matching_results = [{asin: "B001234567", title: "Test Album", artist: "Test Artist"}]
        mock_ai_validation(matching_results)

        stub_request(:get, "https://images.amazon.com/test-image.jpg")
          .to_return(status: 404, body: "Not found")

        result = AmazonProductService.call(album: @album)

        assert result[:success]
        assert_match(/Amazon enrichment completed/, result[:data])

        external_link = @album.external_links.find_by(source: :amazon)
        assert external_link
        assert_equal "https://amazon.com/dp/B001234567", external_link.url
        assert_equal "product_link", external_link.link_category
        assert_equal "The Dark Side of the Moon", external_link.name
      end

      # OffersV2 replaced Offers.Summaries in the Creators API: prices now live on
      # individual listings, so "lowest new price" has to be computed, not read.
      test "call stores the lowest new-condition price from the OffersV2 listings" do
        mock_amazon_api
        mock_ai_validation([{asin: "B001234567", title: "Test Album", artist: "Test Artist"}])

        stub_request(:get, "https://images.amazon.com/test-image.jpg")
          .to_return(status: 404, body: "Not found")

        AmazonProductService.call(album: @album)

        # Listings are 39.99 (new), 12.99 (new) and 4.50 (used) - lowest NEW wins.
        assert_equal 1299, @album.external_links.find_by(source: :amazon).price_cents
      end

      test "call skips image download when album already has primary image" do
        @album.images.create!(primary: true) do |image|
          image.file.attach(
            io: StringIO.new("fake image data"),
            filename: "existing.jpg",
            content_type: "image/jpeg"
          )
        end

        mock_amazon_api
        mock_ai_validation([{asin: "B001234567", title: "Test Album", artist: "Test Artist"}])

        result = AmazonProductService.call(album: @album)

        assert result[:success]
        assert_not_requested :get, /images\.amazon\.com/
      end

      test "call downloads image from best ranked product" do
        @album.images.where(primary: true).destroy_all

        mock_amazon_api_with_images

        matching_results = [
          {asin: "B001234567", title: "Test Album", artist: "Test Artist"},
          {asin: "B007654321", title: "Test Album Deluxe", artist: "Test Artist"}
        ]
        mock_ai_validation(matching_results)

        stub_request(:get, "https://images.amazon.com/best-image.jpg")
          .to_return(status: 200, body: "fake image data", headers: {"Content-Type" => "image/jpeg"})

        result = AmazonProductService.call(album: @album)

        assert result[:success]
        assert_requested :get, "https://images.amazon.com/best-image.jpg"
        assert @album.images.where(primary: true).exists?
      end

      # The best-ranked product is not always the one with a cover. The old code
      # filtered to products WITH an image before ranking; regressing that leaves
      # the album with no cover at all.
      test "call falls through to the next ranked product when the best has no image" do
        @album.images.where(primary: true).destroy_all

        search_results = [
          {
            "asin" => "B00NOIMAGE1",
            "detailPageURL" => "https://amazon.com/dp/B00NOIMAGE1",
            "itemInfo" => {"title" => {"displayValue" => "The Dark Side of the Moon"}},
            "browseNodeInfo" => {"websiteSalesRank" => {"salesRank" => 1}}
          },
          {
            "asin" => "B00HASIMAGE",
            "detailPageURL" => "https://amazon.com/dp/B00HASIMAGE",
            "itemInfo" => {"title" => {"displayValue" => "The Dark Side of the Moon Deluxe"}},
            "images" => {"primary" => {"large" => {"url" => "https://images.amazon.com/fallback.jpg"}}},
            "browseNodeInfo" => {"websiteSalesRank" => {"salesRank" => 900}}
          }
        ]
        ::Services::Amazon::Client.stubs(:search_items).returns(search_results)
        mock_ai_validation([
          {asin: "B00NOIMAGE1", title: "The Dark Side of the Moon", artist: "Pink Floyd"},
          {asin: "B00HASIMAGE", title: "The Dark Side of the Moon Deluxe", artist: "Pink Floyd"}
        ])

        stub_request(:get, "https://images.amazon.com/fallback.jpg")
          .to_return(status: 200, body: "fake image data", headers: {"Content-Type" => "image/jpeg"})

        result = AmazonProductService.call(album: @album)

        assert result[:success]
        assert_requested :get, "https://images.amazon.com/fallback.jpg"
        assert @album.reload.images.where(primary: true).exists?
      end

      test "call handles Amazon API errors gracefully" do
        ::Services::Amazon::Client.stubs(:search_items).raises(StandardError, "API error")

        result = AmazonProductService.call(album: @album)

        refute result[:success]
        assert_match(/Amazon API search failed/, result[:error])
      end

      test "call searches Amazon by artist and title within the Music index" do
        ::Services::Amazon::Client.expects(:search_items)
          .with(has_entries(artist: "Pink Floyd", title: @album.title, search_index: "Music"))
          .returns([])

        result = AmazonProductService.call(album: @album)

        assert result[:success]
      end

      test "call handles AI task failures gracefully" do
        mock_amazon_api

        ai_task = mock
        ai_result = mock
        ai_result.stubs(:success?).returns(false)
        ai_result.stubs(:error).returns("AI processing failed")
        ai_result.stubs(:data).returns(nil)
        ai_task.stubs(:call).returns(ai_result)

        Services::Ai::Tasks::Music::AmazonAlbumMatchTask.stubs(:new).returns(ai_task)

        result = AmazonProductService.call(album: @album)

        refute result[:success]
        assert_equal "AI validation failed: AI processing failed", result[:error]
      end

      private

      def mock_amazon_api
        search_results = [
          {
            "asin" => "B001234567",
            "detailPageURL" => "https://amazon.com/dp/B001234567",
            "itemInfo" => {
              "title" => {"displayValue" => "The Dark Side of the Moon"},
              "byLineInfo" => {
                "contributors" => [{"role" => "Artist", "name" => "Pink Floyd"}]
              }
            },
            "images" => {
              "primary" => {
                "large" => {"url" => "https://images.amazon.com/test-image.jpg"}
              }
            },
            "offersV2" => {
              "listings" => [
                {"condition" => {"value" => "New"}, "price" => {"money" => {"amount" => 39.99}}},
                {"condition" => {"value" => "New"}, "price" => {"money" => {"amount" => 12.99}}},
                {"condition" => {"value" => "Used"}, "price" => {"money" => {"amount" => 4.50}}}
              ]
            }
          }
        ]

        stub_amazon_client(search_results)
      end

      def mock_amazon_api_with_images
        search_results = [
          {
            "asin" => "B001234567",
            "detailPageURL" => "https://amazon.com/dp/B001234567",
            "itemInfo" => {"title" => {"displayValue" => "The Dark Side of the Moon"}},
            "images" => {"primary" => {"large" => {"url" => "https://images.amazon.com/best-image.jpg"}}},
            "browseNodeInfo" => {"websiteSalesRank" => {"salesRank" => 100}}
          },
          {
            "asin" => "B007654321",
            "detailPageURL" => "https://amazon.com/dp/B007654321",
            "itemInfo" => {"title" => {"displayValue" => "The Dark Side of the Moon Deluxe"}},
            "images" => {"primary" => {"large" => {"url" => "https://images.amazon.com/other-image.jpg"}}},
            "browseNodeInfo" => {"websiteSalesRank" => {"salesRank" => 500}}
          }
        ]

        stub_amazon_client(search_results)
      end

      def stub_amazon_client(search_results)
        ::Services::Amazon::Client.stubs(:search_items).returns(search_results)
      end

      def mock_ai_validation(matching_results)
        ai_task = mock
        ai_result = mock
        ai_result.stubs(:success?).returns(true)
        ai_result.stubs(:data).returns({matching_results: matching_results})
        ai_task.stubs(:call).returns(ai_result)

        Services::Ai::Tasks::Music::AmazonAlbumMatchTask.stubs(:new).returns(ai_task)
      end
    end
  end
end
