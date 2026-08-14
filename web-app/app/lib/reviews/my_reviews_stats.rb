# frozen_string_literal: true

module Reviews
  # The numbers behind the /my/reviews profile strip. Two grouped queries, no
  # per-row work -- the strip re-renders on every filter click.
  class MyReviewsStats
    RATINGS = (1..5)

    def initialize(user:, reviewable_class:)
      @user = user
      @reviewable_class = reviewable_class
    end

    def counts_by_rating
      @counts_by_rating ||= RATINGS.index_with { |rating| raw_counts[rating].to_i }
    end

    def total
      @total ||= counts_by_rating.values.sum
    end

    def written
      @written ||= scope.where.not(body: nil).count
    end

    def rating_only
      total - written
    end

    # Explicit Float bounds, and Float on the way out. Integer#/ would floor, and
    # a bare round can hand back an Integer -- both break the one-decimal contract
    # the view formats against.
    def average
      return nil if total.zero?

      sum = counts_by_rating.sum { |rating, count| rating * count }
      (sum.to_f / total).round(1)
    end

    # Relative to the tallest bar, so a spread of 3/1/1 still reads as a chart
    # rather than three near-identical stubs.
    def percentage_for(rating)
      tallest = counts_by_rating.values.max.to_i
      return 0 if tallest.zero?

      ((counts_by_rating[rating].to_f / tallest) * 100).round
    end

    private

    def scope
      @user.reviews.where(reviewable_type: @reviewable_class.name)
    end

    def raw_counts
      @raw_counts ||= scope.group(:rating).count
    end
  end
end
