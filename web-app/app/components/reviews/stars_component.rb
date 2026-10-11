# frozen_string_literal: true

module Reviews
  # Five stars, each filled separately to clamp(rating - i, 0, 1) -- the way
  # Goodreads draws them. A per-star fill (rather than one strip clipped across
  # the row) keeps the inter-star gaps from shifting the cut: at size-4 the old
  # strip filled ~49% of the fourth star for a 3.5.
  #
  # Fill is a single colour throughout. The information is carried by how far the fill
  # extends and by the number printed beside it, never by hue.
  #
  # `exact:` is for a single reader's rating (3.75 reads "3.75"); the default
  # is an average, rounded to one decimal.
  class StarsComponent < ViewComponent::Base
    MAX_RATING = 5

    def initialize(rating:, size: "size-4", label: nil, exact: false)
      @rating = rating
      @size = size
      @label = label
      @exact = exact
    end

    private

    attr_reader :rating, :size

    # One decimal, so 79.2% survives instead of collapsing to 79%.
    def star_fills
      Array.new(MAX_RATING) { |index| ((clamped_rating - index).clamp(0.0, 1.0) * 100).round(1) }
    end

    def label
      return @label if @label
      return "Not yet rated" if rating.nil?

      value = @exact ? Review.format_rating(clamped_rating) : clamped_rating.round(1)
      "#{value} out of #{MAX_RATING} stars"
    end

    # Shared by star_fills and label so the visual fill and the accessible
    # name never disagree -- an out-of-range rating (e.g. 9) must read as
    # "5.0 out of 5 stars", not the raw, unclamped input.
    def clamped_rating
      rating.to_f.clamp(0.0, MAX_RATING.to_f)
    end

    # `fill-current` is a CSS declaration and so beats the `fill="none"` presentation
    # attribute baked into the vendored Lucide source.
    def star(filled:)
      classes = filled ? "#{size} shrink-0 fill-current" : "#{size} shrink-0"
      helpers.icon("star", library: "lucide", class: classes)
    end
  end
end
