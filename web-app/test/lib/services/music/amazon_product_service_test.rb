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
        original_access_key = ENV["AMAZON_PRODUCT_API_ACCESS_KEY"]
        ENV["AMAZON_PRODUCT_API_ACCESS_KEY"] = nil

        begin
          result = AmazonProductService.call(album: @album)

          refute result[:success]
          assert_equal "Amazon API search failed: Amazon API credentials not configured", result[:error]
        ensure
          ENV["AMAZON_PRODUCT_API_ACCESS_KEY"] = original_access_key
        end
      end

      test "call returns success when no matching products found after AI validation" do
        # Mock Amazon API to return products
        mock_amazon_api

        # Mock AI validation to return empty results
        mock_ai_validation([])

        result = AmazonProductService.call(album: @album)

        assert result[:success]
        assert_equal "No matching products found", result[:data]
      end

      test "call creates external links for validated products" do
        # Mock Amazon API to return products
        mock_amazon_api

        # Mock AI validation to return matching results
        matching_results = [{asin: "B001234567", title: "Test Album", artist: "Test Artist"}]
        mock_ai_validation(matching_results)

        # Stub image download to prevent HTTP calls
        stub_request(:get, "https://images.amazon.com/test-image.jpg")
          .to_return(status: 404, body: "Not found")

        result = AmazonProductService.call(album: @album)

        assert result[:success]
        assert_match(/Amazon enrichment completed/, result[:data])

        # Check that external link was created
        external_link = @album.external_links.find_by(source: :amazon)
        assert external_link
        assert_equal "https://amazon.com/dp/B001234567", external_link.url
        assert_equal "product_link", external_link.link_category
      end

      test "call skips image download when album already has primary image" do
        # Create existing primary image
        @album.images.create!(primary: true) do |image|
          image.file.attach(
            io: StringIO.new("fake image data"),
            filename: "existing.jpg",
            content_type: "image/jpeg"
          )
        end

        # Mock Amazon API and AI validation
        mock_amazon_api
        matching_results = [{asin: "B001234567", title: "Test Album", artist: "Test Artist"}]
        mock_ai_validation(matching_results)

        # Should not make any image download requests
        assert_not_requested :get, /images\.amazon\.com/

        result = AmazonProductService.call(album: @album)

        assert result[:success]
      end

      test "call downloads image from best ranked product" do
        # Ensure album has no primary image
        @album.images.where(primary: true).destroy_all

        # Mock Amazon API to return products with images and sales ranks
        mock_amazon_api_with_images

        # Mock AI validation
        matching_results = [
          {asin: "B001234567", title: "Test Album", artist: "Test Artist"},
          {asin: "B007654321", title: "Test Album Deluxe", artist: "Test Artist"}
        ]
        mock_ai_validation(matching_results)

        # Stub image download
        stub_request(:get, "https://images.amazon.com/best-image.jpg")
          .to_return(
            status: 200,
            body: "fake image data",
            headers: {"Content-Type" => "image/jpeg"}
          )

        result = AmazonProductService.call(album: @album)

        assert result[:success]

        # Verify image download was attempted
        assert_requested :get, "https://images.amazon.com/best-image.jpg"

        # Check that image was created
        assert @album.images.where(primary: true).exists?
      end

      test "call handles Amazon API errors gracefully" do
        # Mock Vacuum client to raise an error
        client = mock
        client.stubs(:search_items).raises(StandardError, "API error")
        Vacuum.stubs(:new).returns(client)

        result = AmazonProductService.call(album: @album)

        refute result[:success]
        assert_match(/Amazon API search failed/, result[:error])
      end

      test "call handles AI task failures gracefully" do
        # Mock Amazon API to return products
        mock_amazon_api

        # Mock AI task to fail
        ai_task = mock
        ai_result = mock
        ai_result.stubs(:success?).returns(false)
        ai_result.stubs(:error).returns("AI processing failed")
        ai_result.stubs(:data).returns(nil)
        ai_task.stubs(:call).returns(ai_result)

        Services::Ai::Tasks::AmazonAlbumMatchTask.stubs(:new).returns(ai_task)

        result = AmazonProductService.call(album: @album)

        refute result[:success]
        assert_equal "AI validation failed: AI processing failed", result[:error]
      end

      private

      def mock_amazon_api
        search_results = [
          {
            "ASIN" => "B001234567",
            "DetailPageURL" => "https://amazon.com/dp/B001234567",
            "ItemInfo" => {
              "Title" => {"DisplayValue" => "The Dark Side of the Moon"},
              "ByLineInfo" => {
                "Contributors" => [{"Role" => "Artist", "Name" => "Pink Floyd"}]
              }
            },
            "Images" => {
              "Primary" => {
                "Large" => {"URL" => "https://images.amazon.com/test-image.jpg"}
              }
            },
            "Offers" => {
              "Summaries" => [
                {
                  "Condition" => {"Value" => "New"},
                  "LowestPrice" => {"Amount" => 12.99}
                }
              ]
            }
          }
        ]

        mock_vacuum_client(search_results)
      end

      def mock_amazon_api_with_images
        search_results = [
          {
            "ASIN" => "B001234567",
            "DetailPageURL" => "https://amazon.com/dp/B001234567",
            "ItemInfo" => {
              "Title" => {"DisplayValue" => "The Dark Side of the Moon"}
            },
            "Images" => {
              "Primary" => {
                "Large" => {"URL" => "https://images.amazon.com/best-image.jpg"}
              }
            },
            "BrowseNodeInfo" => {
              "WebsiteSalesRank" => {"SalesRank" => 100}
            }
          },
          {
            "ASIN" => "B007654321",
            "DetailPageURL" => "https://amazon.com/dp/B007654321",
            "ItemInfo" => {
              "Title" => {"DisplayValue" => "The Dark Side of the Moon Deluxe"}
            },
            "Images" => {
              "Primary" => {
                "Large" => {"URL" => "https://images.amazon.com/other-image.jpg"}
              }
            },
            "BrowseNodeInfo" => {
              "WebsiteSalesRank" => {"SalesRank" => 500}
            }
          }
        ]

        mock_vacuum_client(search_results)
      end

      def mock_vacuum_client(search_results)
        client = mock
        response = mock
        response.stubs(:to_h).returns({
          "SearchResult" => {
            "Items" => search_results
          }
        })
        client.stubs(:search_items).returns(response)

        Vacuum.stubs(:new).returns(client)
      end

      def mock_ai_validation(matching_results)
        ai_task = mock
        ai_result = mock
        ai_result.stubs(:success?).returns(true)
        ai_result.stubs(:data).returns({matching_results: matching_results})
        ai_task.stubs(:call).returns(ai_result)

        Services::Ai::Tasks::AmazonAlbumMatchTask.stubs(:new).returns(ai_task)
      end
    end
  end
end
