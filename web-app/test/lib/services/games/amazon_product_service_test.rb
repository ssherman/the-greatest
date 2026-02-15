# frozen_string_literal: true

require "test_helper"

module Services
  module Games
    class AmazonProductServiceTest < ActiveSupport::TestCase
      def setup
        @game = games_games(:breath_of_the_wild)
      end

      test "call fails when game title is blank" do
        @game.title = ""

        result = AmazonProductService.call(game: @game)

        refute result[:success]
        assert_equal "Game title required", result[:error]
      end

      test "call returns success when Amazon API credentials not configured" do
        ENV.stubs(:[]).with("AMAZON_PRODUCT_API_ACCESS_KEY").returns(nil)
        ENV.stubs(:[]).with("AMAZON_PRODUCT_API_SECRET_KEY").returns(nil)
        ENV.stubs(:[]).with("AMAZON_PRODUCT_API_PARTNER_KEY").returns(nil)

        result = AmazonProductService.call(game: @game)

        refute result[:success]
        assert_includes result[:error], "Amazon API"
      end

      test "call returns success with no products message when search returns empty" do
        mock_client = mock
        mock_client.expects(:search_items).returns(
          stub(to_h: {"SearchResult" => {"Items" => []}})
        )

        Vacuum.stubs(:new).returns(mock_client)
        stub_env_credentials

        result = AmazonProductService.call(game: @game)

        assert result[:success]
        assert_equal "No products found", result[:data]
      end

      test "call creates external links for validated products" do
        mock_client = mock
        mock_client.expects(:search_items).returns(
          stub(to_h: {
            "SearchResult" => {
              "Items" => [
                {
                  "ASIN" => "B01MS6MO77",
                  "DetailPageURL" => "https://amazon.com/dp/B01MS6MO77",
                  "ItemInfo" => {
                    "Title" => {"DisplayValue" => "Zelda BotW"}
                  }
                }
              ]
            }
          })
        )

        ai_result = stub(
          success?: true,
          data: {
            matching_results: [
              {asin: "B01MS6MO77", title: "Zelda BotW", product_type: "game", explanation: "Match"}
            ]
          }
        )

        Vacuum.stubs(:new).returns(mock_client)
        stub_env_credentials
        ::Services::Ai::Tasks::Games::AmazonGameMatchTask.any_instance.stubs(:call).returns(ai_result)

        assert_difference "ExternalLink.count", 1 do
          result = AmazonProductService.call(game: @game)

          assert result[:success]
        end

        link = @game.external_links.last
        assert_equal "amazon", link.source
        assert_equal "Zelda BotW", link.name
        assert_equal "game", link.metadata["product_type"]
      end

      test "call does not download images (IGDB only for cover art)" do
        mock_client = mock
        mock_client.expects(:search_items).returns(
          stub(to_h: {
            "SearchResult" => {
              "Items" => [
                {
                  "ASIN" => "B01MS6MO77",
                  "DetailPageURL" => "https://amazon.com/dp/B01MS6MO77",
                  "ItemInfo" => {
                    "Title" => {"DisplayValue" => "Zelda BotW"}
                  },
                  "Images" => {
                    "Primary" => {"Large" => {"URL" => "https://images.amazon.com/image.jpg"}}
                  }
                }
              ]
            }
          })
        )

        ai_result = stub(
          success?: true,
          data: {
            matching_results: [
              {asin: "B01MS6MO77", title: "Zelda BotW", product_type: "game", explanation: "Match"}
            ]
          }
        )

        Vacuum.stubs(:new).returns(mock_client)
        stub_env_credentials
        ::Services::Ai::Tasks::Games::AmazonGameMatchTask.any_instance.stubs(:call).returns(ai_result)

        # Should NOT call Down.download for images
        Down.expects(:download).never

        AmazonProductService.call(game: @game)
      end

      private

      def stub_env_credentials
        ENV.stubs(:[]).with("AMAZON_PRODUCT_API_ACCESS_KEY").returns("test_key")
        ENV.stubs(:[]).with("AMAZON_PRODUCT_API_SECRET_KEY").returns("test_secret")
        ENV.stubs(:[]).with("AMAZON_PRODUCT_API_PARTNER_KEY").returns("test_partner")
      end
    end
  end
end
