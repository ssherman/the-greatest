require "test_helper"

module Services
  module Books
    module GenrePlan
      class ReferencesTest < ActiveSupport::TestCase
        test "counts saved searches and recommendation settings per category id, in either storage shape" do
          saved_searches(:books_public).update_column(:criteria, {"included_category_ids" => ["5"], "excluded_category_ids" => [7]})
          saved_searches(:books_private).update_column(:criteria, {"excluded_category_ids" => ["7", 7]})
          recommendation_configs(:regular_user_books).update_column(:criteria, {"excluded_category_ids" => [7]})

          counts = References.call

          assert_equal 1, counts[5]
          assert_equal 3, counts[7]
          assert_equal 0, counts[99]
        end
      end
    end
  end
end
