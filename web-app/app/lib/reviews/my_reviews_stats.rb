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
      body_counts[false].to_i
    end

    # Counted, not derived: written includes reviews with no rating, which total
    # (rated reviews) does not, so total - written is no longer a count of anything.
    def rating_only
      body_counts[true].to_i
    end

    # The exact mean, not a bucket-weighted one: with fractional ratings the
    # buckets are a rounding, and averaging the rounding drifts. Float on the way
    # out so the one-decimal contract the view formats against holds.
    def average
      return nil if total.zero?

      (rating_sum.to_f / total).round(1)
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

    # One grouped query for both written and rating_only: {false => written, true => rating-only}.
    def body_counts
      @body_counts ||= scope.group(Arel.sql("reviews.body IS NULL")).count
    end

    # One grouped query yields both the bucket counts and the exact sum, so the
    # average costs no extra query.
    def bucket_rows
      @bucket_rows ||= scope.group(Arel.sql(Review::RATING_BUCKET_SQL))
        .pluck(Arel.sql(Review::RATING_BUCKET_SQL), Arel.sql("COUNT(reviews.rating)"), Arel.sql("COALESCE(SUM(reviews.rating), 0)"))
    end

    def raw_counts
      @raw_counts ||= bucket_rows.to_h { |bucket, count, _| [bucket, count] }
    end

    def rating_sum
      bucket_rows.sum { |_, _, sum| sum }
    end
  end
end
