# == Schema Information
#
# Table name: review_summaries
#
#  id                 :bigint           not null, primary key
#  rating_1_count     :integer          default(0), not null
#  rating_2_count     :integer          default(0), not null
#  rating_3_count     :integer          default(0), not null
#  rating_4_count     :integer          default(0), not null
#  rating_5_count     :integer          default(0), not null
#  ratings_count      :integer          default(0), not null
#  ratings_sum        :integer          default(0), not null
#  reviewable_type    :string           not null
#  text_reviews_count :integer          default(0), not null
#  created_at         :datetime         not null
#  updated_at         :datetime         not null
#  reviewable_id      :bigint           not null
#
# Indexes
#
#  index_review_summaries_on_reviewable  (reviewable_type,reviewable_id) UNIQUE
#
# Denormalized rating aggregate, one row per reviewable. Written only by
# Services::Reviews::SummaryRecalculator -- never assign these counters directly.
#
# The average is derived rather than stored, so it can never drift from the counts
# it summarizes.
class ReviewSummary < ApplicationRecord
  belongs_to :reviewable, polymorphic: true

  def average_rating
    return nil if ratings_count.to_i.zero?

    ratings_sum.to_f / ratings_count
  end

  def rating_counts
    {
      1 => rating_1_count,
      2 => rating_2_count,
      3 => rating_3_count,
      4 => rating_4_count,
      5 => rating_5_count
    }
  end

  def rating_percentage(rating)
    return 0.0 if ratings_count.to_i.zero?

    (rating_counts.fetch(rating).to_f / ratings_count) * 100
  end
end
