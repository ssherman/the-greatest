# frozen_string_literal: true

module Services
  module Books
    module GenrePlan
      # How many saved searches and recommendation settings name each category
      # id (included or excluded). Ids are stored as integers or strings.
      class References
        KEYS = %w[included_category_ids excluded_category_ids].freeze

        def self.call
          counts = Hash.new(0)
          [::Books::SavedSearch, ::Books::RecommendationConfig].each do |model|
            model.find_each do |record|
              criteria = record.criteria || {}
              KEYS.flat_map { |key| Array(criteria[key]) }.filter_map { |v| Integer(v.to_s, exception: false) }.uniq
                .each { |id| counts[id] += 1 }
            end
          end
          counts
        end
      end
    end
  end
end
