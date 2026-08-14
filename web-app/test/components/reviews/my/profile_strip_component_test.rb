# frozen_string_literal: true

require "test_helper"

module Reviews
  module My
    class ProfileStripComponentTest < ViewComponent::TestCase
      def stats_for(user)
        Reviews::MyReviewsStats.new(user: user, reviewable_class: ::Books::Book)
      end

      def render_strip(user: users(:regular_user), selected_rating: nil)
        render_inline(Reviews::My::ProfileStripComponent.new(
          stats: stats_for(user),
          selected_rating: selected_rating,
          path_for_rating: ->(rating) { rating ? "/my/reviews?rating=#{rating}" : "/my/reviews" }
        ))
      end

      test "renders the average and the counts" do
        stats = stats_for(users(:regular_user))
        render_strip
        assert_text stats.average.to_s, normalize_ws: true
        assert_selector "[data-testid='my-reviews-total']", text: /\A#{stats.total}\z/
        assert_selector "[data-testid='my-reviews-written']", text: /\A#{stats.written}\z/
      end

      test "every rating is a link that filters, including empty ones" do
        render_strip
        (1..5).each do |rating|
          assert_selector "a[href='/my/reviews?rating=#{rating}']"
        end
      end

      test "the selected rating is marked and offers a way back to all" do
        render_strip(selected_rating: 5)
        assert_selector "[data-testid='rating-bar-5'][aria-current='true']"
        assert_selector "a[href='/my/reviews']"
      end

      test "renders a zero state without dividing by zero" do
        render_strip(user: users(:contractor_user))
        assert_selector "[data-testid='my-reviews-total']", text: /\A0\z/
      end
    end
  end
end
