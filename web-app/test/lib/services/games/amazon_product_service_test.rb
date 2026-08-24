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

      test "call fails when Amazon API credentials not configured" do
        ::Services::Amazon::Client.stubs(:search_items)
          .raises(::Services::Amazon::Client::Error, "Amazon API credentials not configured (AMAZON_PRODUCT_API_CRED_ID is missing)")

        result = AmazonProductService.call(game: @game)

        refute result[:success]
        assert_includes result[:error], "Amazon API"
        assert_includes result[:error], "credentials not configured"
      end

      test "call returns success with no products message when search returns empty" do
        ::Services::Amazon::Client.stubs(:search_items).returns([])

        result = AmazonProductService.call(game: @game)

        assert result[:success]
        assert_equal "No products found", result[:data]
      end

      test "call searches every category so guides and soundtracks are found too" do
        ::Services::Amazon::Client.expects(:search_items)
          .with(has_entries(keywords: @game.title, search_index: "All"))
          .returns([])

        result = AmazonProductService.call(game: @game)

        assert result[:success]
      end

      test "call creates external links for validated products" do
        ::Services::Amazon::Client.stubs(:search_items).returns([
          {
            "asin" => "B01MS6MO77",
            "detailPageURL" => "https://amazon.com/dp/B01MS6MO77",
            "itemInfo" => {"title" => {"displayValue" => "Zelda BotW"}}
          }
        ])
        stub_ai_match

        assert_difference "ExternalLink.count", 1 do
          result = AmazonProductService.call(game: @game)

          assert result[:success]
        end

        link = @game.external_links.last
        assert_equal "amazon", link.source
        assert_equal "Zelda BotW", link.name
        assert_equal "game", link.metadata["product_type"]
      end

      # OffersV2 replaced Offers.Summaries in the Creators API: prices now live on
      # individual listings, so "lowest new price" has to be computed, not read.
      test "call stores the lowest new-condition price from the OffersV2 listings" do
        ::Services::Amazon::Client.stubs(:search_items).returns([
          {
            "asin" => "B01MS6MO77",
            "detailPageURL" => "https://amazon.com/dp/B01MS6MO77",
            "itemInfo" => {"title" => {"displayValue" => "Zelda BotW"}},
            "offersV2" => {
              "listings" => [
                {"condition" => {"value" => "New"}, "price" => {"money" => {"amount" => 59.99}}},
                {"condition" => {"value" => "New"}, "price" => {"money" => {"amount" => 44.50}}},
                {"condition" => {"value" => "Used"}, "price" => {"money" => {"amount" => 19.99}}}
              ]
            }
          }
        ])
        stub_ai_match

        AmazonProductService.call(game: @game)

        assert_equal 4450, @game.external_links.last.price_cents
      end

      test "call does not download images (IGDB only for cover art)" do
        ::Services::Amazon::Client.stubs(:search_items).returns([
          {
            "asin" => "B01MS6MO77",
            "detailPageURL" => "https://amazon.com/dp/B01MS6MO77",
            "itemInfo" => {"title" => {"displayValue" => "Zelda BotW"}},
            "images" => {"primary" => {"large" => {"url" => "https://images.amazon.com/image.jpg"}}}
          }
        ])
        stub_ai_match

        # Should NOT call Down.download for images
        Down.expects(:download).never

        AmazonProductService.call(game: @game)
      end

      private

      def stub_ai_match
        ai_result = stub(
          success?: true,
          data: {
            matching_results: [
              {asin: "B01MS6MO77", title: "Zelda BotW", product_type: "game", explanation: "Match"}
            ]
          }
        )
        ::Services::Ai::Tasks::Games::AmazonGameMatchTask.any_instance.stubs(:call).returns(ai_result)
      end
    end
  end
end
