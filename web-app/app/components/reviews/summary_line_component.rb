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
      summary&.any_reviews?
    end

    private

    attr_reader :summary

    # "· 3 ratings · 2 reviews" after the stars; "1 review" alone when nothing is
    # rated, since there are no stars for the dot to follow.
    def counts_text
      parts = []
      parts << pluralize(summary.ratings_count, "rating") if summary.rated?
      parts << pluralize(summary.text_reviews_count, "review") if summary.text_reviews_count.positive?
      text = parts.join(" · ")
      summary.rated? ? "· #{text}" : text
    end

    # "stars" matters: without it this is the only one of the three star labels in the
    # branch (see ReviewComponent#stars_label, StarsComponent's own default) that omits
    # the word, so on the most prominent instance a screen reader announces "Average
    # rating 4.0 out of 5, image" with no clue it is a star rating.
    def stars_label
      "Average rating #{summary.rounded_average_rating} out of 5 stars"
    end
  end
end
