# frozen_string_literal: true

module Reviews
  module My
    # The /my/reviews header: average, the rating spread, and the counts. The bars
    # ARE the rating filter, which is what earns the strip its space.
    class ProfileStripComponent < ViewComponent::Base
      RATINGS = (1..5).to_a.reverse.freeze

      def initialize(stats:, path_for_rating:, selected_rating: nil)
        @stats = stats
        @selected_rating = selected_rating
        @path_for_rating = path_for_rating
      end

      private

      attr_reader :stats, :selected_rating, :path_for_rating

      def ratings = RATINGS

      def selected?(rating) = selected_rating == rating

      def path_for(rating) = path_for_rating.call(rating)
    end
  end
end
