# frozen_string_literal: true

module Reviews
  # A five-star rating drawn by clipping, not by counting: an outline track with a
  # filled copy laid over it and clipped to rating/5. A fractional average therefore
  # renders as a genuinely partial star instead of being rounded to a whole one, and
  # an integer rating clips exactly on a star boundary -- so one component serves both
  # the average on the summary line and the rating on a single review.
  #
  # Fill is a single colour throughout. The information is carried by how far the fill
  # extends and by the number printed beside it, never by hue.
  class StarsComponent < ViewComponent::Base
    MAX_RATING = 5

    def initialize(rating:, size: "size-4", label: nil)
      @rating = rating
      @size = size
      @label = label
    end

    private

    attr_reader :rating, :size

    # One decimal, so 79.2% survives instead of collapsing to 79%.
    def fill_percentage
      return 0.0 if rating.nil?

      (clamped_rating / MAX_RATING * 100).round(1)
    end

    def label
      return @label if @label
      return "Not yet rated" if rating.nil?

      "#{clamped_rating.round(1)} out of #{MAX_RATING} stars"
    end

    # Shared by fill_percentage and label so the visual fill and the accessible
    # name never disagree -- an out-of-range rating (e.g. 9) must read as
    # "5.0 out of 5 stars", not the raw, unclamped input.
    def clamped_rating
      rating.to_f.clamp(0.0, MAX_RATING.to_f)
    end

    def star_row(filled:)
      safe_join(Array.new(MAX_RATING) { star(filled: filled) })
    end

    # `shrink-0` matters: these are flex items inside a clipped, fixed-width overlay,
    # and without it they squeeze as the fill percentage falls.
    #
    # `fill-current` is a CSS declaration and so beats the `fill="none"` presentation
    # attribute baked into the vendored Lucide source.
    def star(filled:)
      classes = filled ? "#{size} shrink-0 fill-current" : "#{size} shrink-0"
      helpers.icon("star", library: "lucide", class: classes)
    end
  end
end
