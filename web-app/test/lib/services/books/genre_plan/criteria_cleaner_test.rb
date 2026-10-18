require "test_helper"

module Services
  module Books
    module GenrePlan
      class CriteriaCleanerTest < ActiveSupport::TestCase
        test "removes deleted ids from included and excluded lists, in either storage shape" do
          touched = saved_searches(:books_public)
          untouched = saved_searches(:books_private)
          config = recommendation_configs(:regular_user_books)
          touched.update_column(:criteria, {"genre_match_mode" => "any", "included_category_ids" => [5, "9"], "excluded_category_ids" => ["5"]})
          untouched.update_column(:criteria, {"included_category_ids" => [9]})
          config.update_column(:criteria, {"excluded_category_ids" => [5], "max_ranked_position" => 500})

          result = CriteriaCleaner.call(deleted_ids: [5])

          assert_equal ["9"], touched.reload.criteria["included_category_ids"].map(&:to_s)
          assert_empty touched.criteria["excluded_category_ids"]
          assert_equal "any", touched.criteria["genre_match_mode"]
          assert_equal [9], untouched.reload.criteria["included_category_ids"]
          assert_empty config.reload.criteria["excluded_category_ids"]
          assert_equal 500, config.criteria["max_ranked_position"]
          assert_equal [touched.id], result.data[:saved_searches]
          assert_equal [config.id], result.data[:recommendation_configs]
        end

        test "no deleted ids changes nothing" do
          result = CriteriaCleaner.call(deleted_ids: [])
          assert_equal({saved_searches: [], recommendation_configs: []}, result.data)
        end
      end
    end
  end
end
