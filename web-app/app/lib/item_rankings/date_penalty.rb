# frozen_string_literal: true

module ItemRankings
  # Pure legacy per-item "list dates" recency penalty, mirroring the legacy
  # TheGreatestBooks calculate_score_penalty. Returns a penalty fraction (0..1)
  # or nil (no penalty). Order matches legacy: award lists and items with an
  # unknown year take the full penalty, checked before the list-year guard.
  class DatePenalty
    def self.call(list_year:, item_year:, yearly_award:, max_age:, max_penalty_percentage:)
      return nil if max_age.nil? || max_penalty_percentage.nil?

      return max_penalty_percentage / 100.0 if yearly_award || item_year.nil?

      return nil if list_year.nil?

      year_difference = list_year - item_year

      penalty = if year_difference <= 0
        max_penalty_percentage / 100.0
      elsif year_difference > max_age
        nil
      else
        p = ((max_age - year_difference).to_f / max_age) * max_penalty_percentage
        p / 100.0
      end

      (penalty == 0) ? nil : penalty
    end
  end
end
