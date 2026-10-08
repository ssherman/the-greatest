# frozen_string_literal: true

module Recommendations
  Profile = Struct.new(:genres, :subjects, :locations, :demoted, :fiction_share, :genre_distribution, :counts,
    keyword_init: true) do
    def empty? = genres.empty? && subjects.empty? && locations.empty?

    def weight_for(category_id)
      weights[category_id]
    end

    def scored_ids
      weights.keys
    end

    private

    def weights
      @weights ||= (genres + subjects + locations).to_h
    end
  end
end
