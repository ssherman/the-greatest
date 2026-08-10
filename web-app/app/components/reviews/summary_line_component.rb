# frozen_string_literal: true

module Reviews
  # The compact rating line that sits under a book's rank. The whole line is the link
  # down to the reviews card, so the number a reader notices is also the way to the
  # detail behind it.
  class SummaryLineComponent < ViewComponent::Base
    ANCHOR = "ratings-reviews"

    def initialize(summary:)
      @summary = summary
    end

    def render?
      summary.present? && summary.ratings_count.positive?
    end

    private

    attr_reader :summary

    def stars_label
      "Average rating #{summary.rounded_average_rating} out of 5"
    end
  end
end
