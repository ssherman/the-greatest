# frozen_string_literal: true

module Reviews
  # The per-star breakdown behind an average. Bars are all one colour -- the length of
  # the bar and the count beside it carry the meaning, never the hue.
  class HistogramComponent < ViewComponent::Base
    def initialize(summary:)
      @summary = summary
    end

    # Nil for the 72,659 books nobody has rated; zero-count rows exist too, because a
    # summary survives the deletion of its last review.
    def render?
      summary.present? && summary.ratings_count.positive?
    end

    private

    attr_reader :summary

    def rows
      5.downto(1).map do |star|
        {
          star: star,
          count: summary.rating_counts.fetch(star),
          percentage: summary.rating_percentage(star).round(1)
        }
      end
    end
  end
end
