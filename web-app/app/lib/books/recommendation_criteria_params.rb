# frozen_string_literal: true

module Books
  # Form params -> the criteria hash RecommendationConfig stores. Delegates the
  # normalization to SavedSearchCriteriaParams and keeps only the recommendation
  # keys, so `ranked`/`hide_read`/language/country never enter the column.
  class RecommendationCriteriaParams
    def self.call(raw)
      ::Books::SavedSearchCriteriaParams.call(raw).slice(*::Books::RecommendationCriteria::KEYS)
    end
  end
end
