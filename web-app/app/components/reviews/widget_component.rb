# frozen_string_literal: true

module Reviews
  # The "Rate this book" control beside Add to list.
  #
  # Renders IDENTICAL HTML for every visitor when `review` is nil -- the book page
  # is edge-cached for 24 hours, so nothing user-specific may be baked into it.
  # JavaScript fills in the rating from the uncached /review_state endpoint.
  #
  # Reviews::StarsComponent is always rendered, even with no review (rating 0,
  # which clips its fill to nothing) -- never conditionally, and never hidden.
  # That keeps this markup identical for every cached visitor, and it means the
  # widget controller only ever has to widen a fill and rename a label on
  # hydration, rather than reveal-or-hide an element that started out empty.
  #
  # The same component renders server-side WITH a review in the Turbo Stream that
  # answers a save. Both paths must produce the same shape, or the widget will
  # look different after saving than it does after a reload.
  class WidgetComponent < ViewComponent::Base
    def initialize(reviewable:, review: nil)
      @reviewable = reviewable
      @review = review
    end

    private

    attr_reader :reviewable, :review

    def reviewable_type
      reviewable.class.name
    end

    def label
      review ? "Edit your review" : "Rate this book"
    end

    def stars_label
      return "Not yet rated" unless review

      "Your rating: #{review.rating} out of 5 stars"
    end
  end
end
