# frozen_string_literal: true

require "test_helper"

module Services
  module Ai
    module Tasks
      class AmazonProductMatchTaskTest < ActiveSupport::TestCase
        # Test subclass that implements all abstract methods
        class TestMatchTask < AmazonProductMatchTask
          def domain_name = "test"
          def item_description = "Test item"
          def match_criteria = "Criteria"
          def non_match_criteria = "Non-criteria"

          class ResponseSchema < OpenAI::BaseModel
            required :matching_results, OpenAI::ArrayOf[String]
          end
        end

        # Minimal subclass that doesn't implement abstract methods
        class IncompleteMatchTask < AmazonProductMatchTask
          class ResponseSchema < OpenAI::BaseModel
            required :matching_results, OpenAI::ArrayOf[String]
          end
        end

        def setup
          @album = music_albums(:dark_side_of_the_moon)
          @search_results = [
            {
              "ASIN" => "B001234",
              "ItemInfo" => {
                "Title" => {"DisplayValue" => "Test Product"}
              }
            }
          ]
        end

        test "raises NotImplementedError for abstract methods" do
          task = IncompleteMatchTask.new(parent: @album, search_results: @search_results)

          assert_raises(NotImplementedError) { task.send(:domain_name) }
          assert_raises(NotImplementedError) { task.send(:item_description) }
          assert_raises(NotImplementedError) { task.send(:match_criteria) }
          assert_raises(NotImplementedError) { task.send(:non_match_criteria) }
        end

        test "provides default task_provider, task_model, and temperature" do
          task = TestMatchTask.new(parent: @album, search_results: @search_results)

          assert_equal :openai, task.send(:task_provider)
          assert_equal "gpt-5-mini", task.send(:task_model)
          assert_equal 1.0, task.send(:temperature)
        end

        test "initializes with search_results" do
          task = TestMatchTask.new(parent: @album, search_results: @search_results)

          assert_equal @search_results, task.search_results
        end

        test "format_search_results formats all results" do
          search_results = [
            {
              "ASIN" => "B001",
              "ItemInfo" => {"Title" => {"DisplayValue" => "Product 1"}}
            },
            {
              "ASIN" => "B002",
              "ItemInfo" => {"Title" => {"DisplayValue" => "Product 2"}}
            }
          ]

          task = TestMatchTask.new(parent: @album, search_results: search_results)
          formatted = task.send(:format_search_results)

          assert_includes formatted, "B001"
          assert_includes formatted, "B002"
          assert_includes formatted, "Product 1"
          assert_includes formatted, "Product 2"
        end
      end
    end
  end
end
