# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Games
    module Game
      class ImporterTest < ActiveSupport::TestCase
        def setup
          @switch = games_platforms(:switch)
          # Stub async jobs since we're testing the importer, not the jobs
          ::Games::CoverArtDownloadJob.stubs(:perform_async)
          ::Games::AmazonProductEnrichmentJob.stubs(:perform_async)
        end

        test "call creates and imports new game" do
          search_service = mock
          search_service.expects(:find_with_details).with(7346).returns(
            success: true,
            data: [
              {
                "name" => "The Legend of Zelda: Breath of the Wild",
                "summary" => "Open-world adventure",
                "first_release_date" => 1488499200,
                "category" => 0,
                "platforms" => [{"name" => "Nintendo Switch", "slug" => "nintendo-switch", "abbreviation" => "Switch"}],
                "genres" => [{"name" => "Adventure"}]
              }
            ]
          )

          ::Games::Igdb::Search::GameSearch.stubs(:new).returns(search_service)

          result = Importer.call(igdb_id: 7346)

          assert result.success?
          assert_instance_of ::Games::Game, result.item
          assert_equal "The Legend of Zelda: Breath of the Wild", result.item.title
          assert result.item.persisted?
          assert_equal 2017, result.item.release_year
          assert_includes result.item.platforms, @switch
        end

        test "call returns existing game when found by identifier" do
          existing_game = games_games(:breath_of_the_wild)
          existing_game.identifiers.create!(
            identifier_type: :games_igdb_id,
            value: "7346"
          )

          # Should not call IGDB API when game already exists
          ::Games::Igdb::Search::GameSearch.expects(:new).never

          result = Importer.call(igdb_id: 7346)

          assert result.success?
          assert_equal existing_game, result.item
        end

        test "call re-runs providers with force_providers true" do
          existing_game = games_games(:breath_of_the_wild)
          existing_game.identifiers.create!(
            identifier_type: :games_igdb_id,
            value: "7346"
          )

          search_service = mock
          search_service.expects(:find_with_details).with(7346).returns(
            success: true,
            data: [
              {
                "name" => "The Legend of Zelda: Breath of the Wild",
                "summary" => "Updated description"
              }
            ]
          )

          ::Games::Igdb::Search::GameSearch.stubs(:new).returns(search_service)

          result = Importer.call(igdb_id: 7346, force_providers: true)

          assert result.success?
          assert_equal existing_game, result.item
          assert_equal "Updated description", result.item.reload.description
        end

        test "call with item parameter re-enriches existing game" do
          existing_game = games_games(:breath_of_the_wild)
          # Add IGDB identifier so provider can look it up
          existing_game.identifiers.create!(
            identifier_type: :games_igdb_id,
            value: "7346"
          )

          search_service = mock
          search_service.expects(:find_with_details).with(7346).returns(
            success: true,
            data: [
              {
                "name" => "The Legend of Zelda: Breath of the Wild",
                "summary" => "Updated description"
              }
            ]
          )

          ::Games::Igdb::Search::GameSearch.stubs(:new).returns(search_service)

          result = Importer.call(item: existing_game)

          assert result.success?
          assert_equal existing_game, result.item
          assert_equal "Updated description", result.item.reload.description
        end

        test "call fails when igdb_id is invalid" do
          error = assert_raises(ArgumentError) do
            Importer.call(igdb_id: "not-an-integer")
          end

          assert_includes error.message, "Invalid query object"
        end

        test "call creates IGDB identifier for new game" do
          search_service = mock
          search_service.expects(:find_with_details).with(7346).returns(
            success: true,
            data: [{"name" => "Zelda BotW"}]
          )

          ::Games::Igdb::Search::GameSearch.stubs(:new).returns(search_service)

          result = Importer.call(igdb_id: 7346)

          assert result.success?
          identifier = result.item.identifiers.find_by(identifier_type: :games_igdb_id)
          assert_not_nil identifier
          assert_equal "7346", identifier.value
        end

        test "call handles IGDB API failure" do
          search_service = mock
          search_service.expects(:find_with_details).with(7346).returns(
            success: false,
            errors: ["Network error"]
          )

          ::Games::Igdb::Search::GameSearch.stubs(:new).returns(search_service)

          result = Importer.call(igdb_id: 7346)

          refute result.success?
          refute result.item.persisted?
        end

        test "call imports companies recursively" do
          game_search = mock
          game_search.expects(:find_with_details).with(7346).returns(
            success: true,
            data: [
              {
                "name" => "Zelda BotW",
                "involved_companies" => [
                  {
                    "company" => {"id" => 70, "name" => "Nintendo"},
                    "developer" => true,
                    "publisher" => true
                  }
                ]
              }
            ]
          )

          company_search = mock
          company_search.expects(:find_with_details).with(70).returns(
            success: true,
            data: [{"name" => "Nintendo", "country" => 392}]
          )

          ::Games::Igdb::Search::GameSearch.stubs(:new).returns(game_search)
          ::Games::Igdb::Search::CompanySearch.stubs(:new).returns(company_search)

          result = Importer.call(igdb_id: 7346)

          assert result.success?
          assert_equal 1, result.item.companies.count
          assert_equal "Nintendo", result.item.companies.first.name
        end

        test "call can filter to specific providers" do
          existing_game = games_games(:breath_of_the_wild)
          # Add IGDB identifier so provider can look it up
          existing_game.identifiers.create!(
            identifier_type: :games_igdb_id,
            value: "7346"
          )

          search_service = mock
          search_service.expects(:find_with_details).with(7346).returns(
            success: true,
            data: [{"name" => "Updated Title"}]
          )

          ::Games::Igdb::Search::GameSearch.stubs(:new).returns(search_service)

          result = Importer.call(item: existing_game, providers: [:igdb])

          assert result.success?
          assert_equal 1, result.provider_results.count
        end
      end
    end
  end
end
