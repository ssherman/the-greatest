# frozen_string_literal: true

module Books
  # Form params -> the criteria hash RecommendationConfig stores. Delegates the
  # normalization to SavedSearchCriteriaParams and keeps only the recommendation
  # keys, so `ranked`/`hide_read`/language/country never enter the column.
  class RecommendationCriteriaParams
    def self.call(raw)
      out = ::Books::SavedSearchCriteriaParams.call(raw).slice(*::Books::RecommendationCriteria::KEYS)
      depth = (raw || {}).to_h.stringify_keys["depth"].to_s
      stored_depths = ::Books::RecommendationCriteria::DEPTHS - [::Books::RecommendationCriteria::DEFAULT_DEPTH]
      out["depth"] = depth if stored_depths.include?(depth)
      out
    end
  end
end
