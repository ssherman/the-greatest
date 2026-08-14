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

      def written? = review.body.present?

      # Rendered, not stored: markup is generated at render time so what is stored
      # stays exactly what the author typed. Never call BodySanitizer.call here.
      def snippet
        Services::Reviews::BodySanitizer.render(review.body)
      end

      def creators
        return [] unless reviewable.respond_to?(:book_authors)

        reviewable.book_authors.map { |book_author| book_author.author.name }
      end
    end
  end
end
