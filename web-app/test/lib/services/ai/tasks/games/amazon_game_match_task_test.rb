# frozen_string_literal: true

require "test_helper"

module Services
  module Ai
    module Tasks
      module Games
        class AmazonGameMatchTaskTest < ActiveSupport::TestCase
          def setup
            @game = games_games(:breath_of_the_wild)
            @search_results = [
              {
                "ASIN" => "B01MS6MO77",
                "ItemInfo" => {
                  "Title" => {"DisplayValue" => "The Legend of Zelda: Breath of the Wild - Nintendo Switch"},
                  "ByLineInfo" => {
                    "Contributors" => [{"Role" => "Artist", "Name" => "Nintendo"}]
                  },
                  "Classifications" => {"Binding" => {"DisplayValue" => "Video Game"}}
                }
              },
              {
                "ASIN" => "B06XBYCM49",
                "ItemInfo" => {
                  "Title" => {"DisplayValue" => "The Legend of Zelda: Breath of the Wild Official Strategy Guide"},
                  "Classifications" => {"Binding" => {"DisplayValue" => "Paperback"}}
                }
              }
            ]
            @task = AmazonGameMatchTask.new(parent: @game, search_results: @search_results)
          end

          test "initializes with game and search_results" do
            assert_equal @game, @task.send(:parent)
            assert_equal @search_results, @task.search_results
          end

          test "domain_name returns game" do
            assert_equal "game", @task.send(:domain_name)
          end

          test "item_description includes game title" do
            description = @task.send(:item_description)

            assert_includes description, @game.title
          end

          test "item_description includes platforms when present" do
            @game.stubs(:platforms).returns([stub(name: "Nintendo Switch")])

            description = @task.send(:item_description)

            assert_includes description, "Nintendo Switch"
          end

          test "item_description includes release_year when present" do
            description = @task.send(:item_description)

            assert_includes description, "2017"
          end

          test "match_criteria includes game-related products" do
            criteria = @task.send(:match_criteria)

            assert_includes criteria, "Strategy guides"
            assert_includes criteria, "Art books"
            assert_includes criteria, "Official soundtracks"
            assert_includes criteria, "Collectibles"
            assert_includes criteria, "DLC"
          end

          test "non_match_criteria excludes unrelated products" do
            criteria = @task.send(:non_match_criteria)

            assert_includes criteria, "Generic gaming accessories"
            assert_includes criteria, "Fan-made"
            assert_includes criteria, "different games"
          end

          test "system_message contains game expert" do
            system_message = @task.send(:system_message)

            assert_includes system_message, "game expert"
            assert_includes system_message, "Amazon product search result"
          end

          test "user_prompt includes game information" do
            user_prompt = @task.send(:user_prompt)

            assert_includes user_prompt, @game.title
            assert_includes user_prompt, "Amazon search results:"
          end

          test "response_schema includes product_type field" do
            @task.send(:response_schema)
            match_result_schema = AmazonGameMatchTask::MatchResult

            # Verify the schema has product_type field
            assert match_result_schema.respond_to?(:new)
          end

          test "uses gpt-5-mini model" do
            assert_equal "gpt-5-mini", @task.send(:task_model)
          end

          test "uses openai provider" do
            assert_equal :openai, @task.send(:task_provider)
          end
        end
      end
    end
  end
end
