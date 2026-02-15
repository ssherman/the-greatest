# frozen_string_literal: true

require "test_helper"

module DataImporters
  module Games
    module Game
      module Providers
        class IgdbTest < ActiveSupport::TestCase
          def setup
            @provider = Igdb.new
            @game = ::Games::Game.new
            @switch = games_platforms(:switch)
          end

          test "populate sets game attributes from IGDB data" do
            search_service = mock
            search_service.expects(:find_with_details).with(7346).returns(
              success: true,
              data: [
                {
                  "name" => "The Legend of Zelda: Breath of the Wild",
                  "summary" => "An open-world adventure game",
                  "first_release_date" => 1488499200, # March 3, 2017
                  "category" => 0 # main_game
                }
              ]
            )

            ::Games::Igdb::Search::GameSearch.stubs(:new).returns(search_service)

            query = ImportQuery.new(igdb_id: 7346)
            result = @provider.populate(@game, query: query)

            assert result.success?
            assert_equal "The Legend of Zelda: Breath of the Wild", @game.title
            assert_equal "An open-world adventure game", @game.description
            assert_equal 2017, @game.release_year
            assert_equal "main_game", @game.game_type
          end

          test "populate creates IGDB identifier" do
            search_service = mock
            search_service.expects(:find_with_details).with(7346).returns(
              success: true,
              data: [{"name" => "Zelda BotW"}]
            )

            ::Games::Igdb::Search::GameSearch.stubs(:new).returns(search_service)

            query = ImportQuery.new(igdb_id: 7346)
            @provider.populate(@game, query: query)

            identifier = @game.identifiers.find { |i| i.identifier_type == "games_igdb_id" }
            assert_not_nil identifier
            assert_equal "7346", identifier.value
          end

          test "populate maps IGDB category to game_type" do
            test_cases = [
              {igdb_category: 0, expected_type: "main_game"},
              {igdb_category: 1, expected_type: "dlc"},
              {igdb_category: 2, expected_type: "expansion"},
              {igdb_category: 8, expected_type: "remake"},
              {igdb_category: 9, expected_type: "remaster"},
              {igdb_category: 11, expected_type: "port"}
            ]

            test_cases.each_with_index do |tc, idx|
              game = ::Games::Game.new
              provider = Igdb.new
              search_service = stub
              search_service.stubs(:find_with_details).returns(
                success: true,
                data: [{"name" => "Test", "category" => tc[:igdb_category]}]
              )

              ::Games::Igdb::Search::GameSearch.stubs(:new).returns(search_service)

              query = ImportQuery.new(igdb_id: idx + 1)
              provider.populate(game, query: query)

              assert_equal tc[:expected_type], game.game_type,
                "Expected IGDB category #{tc[:igdb_category]} to map to #{tc[:expected_type]}"
            end
          end

          test "populate imports companies recursively" do
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
              data: [{"name" => "Nintendo"}]
            )

            ::Games::Igdb::Search::GameSearch.stubs(:new).returns(game_search)
            ::Games::Igdb::Search::CompanySearch.stubs(:new).returns(company_search)

            query = ImportQuery.new(igdb_id: 7346)
            result = @provider.populate(@game, query: query)

            assert result.success?
            assert_equal 1, @game.game_companies.size

            game_company = @game.game_companies.first
            assert game_company.developer
            assert game_company.publisher
            assert_equal "Nintendo", game_company.company.name
          end

          test "populate updates existing company roles on re-import" do
            # Use fixture company
            company = games_companies(:nintendo)
            company.identifiers.find_or_create_by!(identifier_type: :games_igdb_company_id, value: "70")

            @game.title = "Test Game"
            @game.save!
            existing_join = @game.game_companies.create!(company: company, developer: true, publisher: false)

            # Verify initial state
            assert existing_join.developer
            assert_not existing_join.publisher

            # Re-import with changed roles (developer=false, publisher=true)
            game_search = mock
            game_search.expects(:find_with_details).with(7346).returns(
              success: true,
              data: [
                {
                  "name" => "Test Game Updated",
                  "involved_companies" => [
                    {
                      "company" => {"id" => 70, "name" => "Nintendo"},
                      "developer" => false,
                      "publisher" => true
                    }
                  ]
                }
              ]
            )

            # Stub company importer to return existing company
            company_result = stub(success?: true, item: company)
            DataImporters::Games::Company::Importer.stubs(:call).with(igdb_id: 70).returns(company_result)

            ::Games::Igdb::Search::GameSearch.stubs(:new).returns(game_search)

            # Reload game to get fresh associations
            @game.reload

            query = ImportQuery.new(igdb_id: 7346)
            result = @provider.populate(@game, query: query)

            assert result.success?

            # Save and reload to verify persistence
            @game.save!
            existing_join.reload

            assert_not existing_join.developer, "Developer flag should be updated to false"
            assert existing_join.publisher, "Publisher flag should be updated to true"
          end

          test "populate matches existing platforms by slug" do
            search_service = mock
            search_service.expects(:find_with_details).with(7346).returns(
              success: true,
              data: [
                {
                  "name" => "Zelda BotW",
                  "platforms" => [
                    {"name" => "Nintendo Switch", "slug" => "nintendo-switch", "abbreviation" => "Switch"}
                  ]
                }
              ]
            )

            ::Games::Igdb::Search::GameSearch.stubs(:new).returns(search_service)

            query = ImportQuery.new(igdb_id: 7346)
            result = @provider.populate(@game, query: query)

            assert result.success?
            assert_equal 1, @game.game_platforms.size
            assert_equal @switch, @game.game_platforms.first.platform
          end

          test "populate creates new platforms when not found" do
            search_service = mock
            search_service.expects(:find_with_details).with(7346).returns(
              success: true,
              data: [
                {
                  "name" => "Zelda BotW",
                  "platforms" => [
                    {"name" => "PlayStation 3", "slug" => "ps3", "abbreviation" => "PS3"}
                  ]
                }
              ]
            )

            ::Games::Igdb::Search::GameSearch.stubs(:new).returns(search_service)

            query = ImportQuery.new(igdb_id: 7346)

            assert_difference "::Games::Platform.count", 1 do
              result = @provider.populate(@game, query: query)
              assert result.success?
            end

            platform = ::Games::Platform.find_by(slug: "ps3")
            assert_not_nil platform
            assert_equal "PlayStation 3", platform.name
            assert_equal "PS3", platform.abbreviation
            assert_equal "playstation", platform.platform_family
            assert_equal 1, @game.game_platforms.size
          end

          test "populate infers platform family correctly" do
            test_cases = [
              {slug: "ps4--1", name: "PlayStation 4", expected_family: "playstation"},
              {slug: "xboxone", name: "Xbox One", expected_family: "xbox"},
              {slug: "series-x-s", name: "Xbox Series X|S", expected_family: "xbox"},
              {slug: "switch-2", name: "Nintendo Switch 2", expected_family: "nintendo"},
              {slug: "win", name: "PC (Microsoft Windows)", expected_family: "pc"},
              {slug: "mac", name: "Mac", expected_family: "pc"},
              {slug: "ios", name: "iOS", expected_family: "mobile"},
              {slug: "dreamcast", name: "Dreamcast", expected_family: "other"}
            ]

            test_cases.each do |tc|
              search_service = stub
              search_service.stubs(:find_with_details).returns(
                success: true,
                data: [
                  {
                    "name" => "Test Game",
                    "platforms" => [
                      {"name" => tc[:name], "slug" => tc[:slug], "abbreviation" => "TEST"}
                    ]
                  }
                ]
              )

              ::Games::Igdb::Search::GameSearch.stubs(:new).returns(search_service)

              game = ::Games::Game.new
              provider = Igdb.new
              query = ImportQuery.new(igdb_id: 1)
              provider.populate(game, query: query)

              platform = ::Games::Platform.find_by(slug: tc[:slug])
              assert_not_nil platform, "Platform #{tc[:slug]} should be created"
              assert_equal tc[:expected_family], platform.platform_family,
                "Expected #{tc[:slug]} to have family #{tc[:expected_family]}, got #{platform.platform_family}"
            end
          end

          test "populate skips platforms without slug" do
            search_service = mock
            search_service.expects(:find_with_details).with(7346).returns(
              success: true,
              data: [
                {
                  "name" => "Zelda BotW",
                  "platforms" => [
                    {"name" => "Unknown Platform"}
                  ]
                }
              ]
            )

            ::Games::Igdb::Search::GameSearch.stubs(:new).returns(search_service)

            query = ImportQuery.new(igdb_id: 7346)
            result = @provider.populate(@game, query: query)

            assert result.success?
            assert_equal 0, @game.game_platforms.size
          end

          test "populate creates categories from genres" do
            search_service = mock
            search_service.expects(:find_with_details).with(7346).returns(
              success: true,
              data: [
                {
                  "name" => "Zelda BotW",
                  "genres" => [
                    {"name" => "Adventure"},
                    {"name" => "Action"}
                  ]
                }
              ]
            )

            ::Games::Igdb::Search::GameSearch.stubs(:new).returns(search_service)

            query = ImportQuery.new(igdb_id: 7346)
            @provider.populate(@game, query: query)

            # Save the game first so CategoryItem can be created
            @game.title = "Test"
            @game.save!

            genre_names = @game.categories.where(category_type: :genre).pluck(:name)
            assert_includes genre_names, "Adventure"
            assert_includes genre_names, "Action"
          end

          test "populate creates categories from themes, game_modes, and player_perspectives" do
            search_service = mock
            search_service.expects(:find_with_details).with(7346).returns(
              success: true,
              data: [
                {
                  "name" => "Zelda BotW",
                  "themes" => [{"name" => "Open World"}],
                  "game_modes" => [{"name" => "Single player"}],
                  "player_perspectives" => [{"name" => "Third person"}]
                }
              ]
            )

            ::Games::Igdb::Search::GameSearch.stubs(:new).returns(search_service)

            query = ImportQuery.new(igdb_id: 7346)
            @provider.populate(@game, query: query)

            @game.title = "Test"
            @game.save!

            assert @game.categories.exists?(name: "Open World", category_type: :theme)
            assert @game.categories.exists?(name: "Single player", category_type: :game_mode)
            assert @game.categories.exists?(name: "Third person", category_type: :player_perspective)
          end

          test "populate returns failure when IGDB API fails" do
            search_service = mock
            search_service.expects(:find_with_details).with(7346).returns(
              success: false,
              errors: ["API rate limit exceeded"]
            )

            ::Games::Igdb::Search::GameSearch.stubs(:new).returns(search_service)

            query = ImportQuery.new(igdb_id: 7346)
            result = @provider.populate(@game, query: query)

            refute result.success?
            assert_includes result.errors, "API rate limit exceeded"
          end

          test "populate returns failure when game not found" do
            search_service = mock
            search_service.expects(:find_with_details).with(99999).returns(
              success: true,
              data: []
            )

            ::Games::Igdb::Search::GameSearch.stubs(:new).returns(search_service)

            query = ImportQuery.new(igdb_id: 99999)
            result = @provider.populate(@game, query: query)

            refute result.success?
            assert_includes result.errors, "Game not found in IGDB"
          end

          test "populate continues when company import fails" do
            game_search = mock
            game_search.expects(:find_with_details).with(7346).returns(
              success: true,
              data: [
                {
                  "name" => "Zelda BotW",
                  "involved_companies" => [
                    {
                      "company" => {"id" => 99999},
                      "developer" => true,
                      "publisher" => false
                    }
                  ]
                }
              ]
            )

            company_search = mock
            company_search.expects(:find_with_details).with(99999).returns(
              success: false,
              errors: ["Company not found"]
            )

            ::Games::Igdb::Search::GameSearch.stubs(:new).returns(game_search)
            ::Games::Igdb::Search::CompanySearch.stubs(:new).returns(company_search)

            query = ImportQuery.new(igdb_id: 7346)
            result = @provider.populate(@game, query: query)

            # Should succeed even though company import failed
            assert result.success?
            assert_equal "Zelda BotW", @game.title
            assert_equal 0, @game.game_companies.size
          end
        end
      end
    end
  end
end
