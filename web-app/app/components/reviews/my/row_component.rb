# frozen_string_literal: true

module Reviews
  module My
    # One row of /my/reviews. Written reviews show a clamped snippet; rating-only
    # rows collapse to a single line offering to write one.
    class RowComponent < ViewComponent::Base
      def initialize(review:)
        @review = review
      end

      private

      attr_reader :review

      def reviewable = review.reviewable

      def reviewable_class = reviewable.class

      def written? = review.body.present?

      # Rendered, not stored: markup is generated at render time so what is stored
      # stays exactly what the author typed. Never call BodySanitizer.call here.
      def snippet
        Services::Reviews::BodySanitizer.render(review.body)
      end

      def creators
        reviewable_class.review_creator_names(reviewable)
      end

      def reviewable_path
        reviewable_class.review_public_path(reviewable)
      end
    end
  end
end
