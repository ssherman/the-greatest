# frozen_string_literal: true

module Reviews
  module My
    # One row of /my/reviews. Written reviews show a clamped snippet; rating-only
    # rows collapse to a single line offering to write one.
    class RowComponent < ViewComponent::Base
      # last_on_page tells the delete button that removing this row empties the
      # page it is on. The Stimulus controller then drops the /page/N segment on
      # reload instead of returning to a page that no longer exists --
      # PathBasedPagination#pagy_path raises RecordNotFound past the last page,
      # so deleting the only row on the final page would otherwise 404 the user
      # immediately after a successful delete.
      def initialize(review:, last_on_page: false)
        @review = review
        @last_on_page = last_on_page
      end

      private

      attr_reader :review, :last_on_page

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

      # Names the book so a misclick in a 25-row list is caught by reading the
      # prompt, not by noticing afterwards that the wrong thing went.
      def delete_confirmation
        "Delete your review of #{reviewable.title}? This cannot be undone."
      end
    end
  end
end
