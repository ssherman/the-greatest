# frozen_string_literal: true

module Reviews
  # The Ratings & Reviews card at the foot of a book page: the per-star histogram, then
  # every written review in the order the caller supplied.
  #
  # Unpaginated on purpose. The most-reviewed book in the corpus has 37 written reviews
  # and none has more than 50; paging would be machinery for a case that does not exist,
  # and it would mint crawlable URLs that today would never have a page 2.
  class CardComponent < ViewComponent::Base
    # One definition of the anchor, shared with the line that links to it.
    ANCHOR = Reviews::SummaryLineComponent::ANCHOR

    def initialize(summary:, reviews:)
      @summary = summary
      @reviews = reviews
    end

    def render?
      summary.present? && summary.ratings_count.positive?
    end

    private

    attr_reader :summary, :reviews
  end
end
