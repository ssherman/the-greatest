require "test_helper"

module Api
  module V1
    module Books
      class RankingConfigurationResourceTest < ActiveSupport::TestCase
        setup do
          Current.domain = :books
          @configuration = ranking_configurations(:books_global)
        end

        test "shape" do
          hash = RankingConfigurationResource.new(@configuration, params: {item_count: 12, list_count: 3}).to_h

          assert_equal(
            %i[id name kind primary year description published_at last_refreshed_at item_count list_count url api_url books_api_url],
            hash.keys
          )
          assert_equal @configuration.id, hash[:id]
          assert_equal "Global Books Ranking", hash[:name]
          assert_equal "books", hash[:kind]
          assert_equal true, hash[:primary]
          assert_nil hash[:year]
          assert_equal "The main ranking configuration for books", hash[:description]
          assert_equal "2025-07-09T23:38:50Z", hash[:published_at]
          assert_nil hash[:last_refreshed_at]
          assert_equal 12, hash[:item_count]
          assert_equal 3, hash[:list_count]
          assert_equal "https://dev-new.thegreatestbooks.org/rc/#{@configuration.id}", hash[:url]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{@configuration.id}", hash[:api_url]
          assert_equal "https://dev-new.thegreatestbooks.org/api/v1/ranking_configurations/#{@configuration.id}/books", hash[:books_api_url]
        end

        test "a non-primary configuration with a year" do
          hash = RankingConfigurationResource.new(ranking_configurations(:books_year_2025), params: {item_count: 0, list_count: 0}).to_h

          assert_equal false, hash[:primary]
          assert_equal 2025, hash[:year]
          assert_nil hash[:published_at]
        end

        test "timestamps are ISO 8601 in UTC" do
          @configuration.update!(last_refreshed_at: Time.zone.parse("2026-09-19 08:15:00 UTC"))

          hash = RankingConfigurationResource.new(@configuration, params: {item_count: 0, list_count: 0}).to_h

          assert_equal "2026-09-19T08:15:00Z", hash[:last_refreshed_at]
        end

        test "the counts are required" do
          assert_raises(KeyError) { RankingConfigurationResource.new(@configuration).to_h }
          assert_raises(KeyError) { RankingConfigurationResource.new(@configuration, params: {item_count: 1}).to_h }
        end

        test "the shape carries no algorithm parameters" do
          hash = RankingConfigurationResource.new(@configuration, params: {item_count: 0, list_count: 0}).to_h

          %i[exponent bonus_pool_percentage min_list_weight list_limit algorithm_version].each do |key|
            refute hash.key?(key), key
          end
        end
      end
    end
  end
end
