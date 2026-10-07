# frozen_string_literal: true

module Search
  module Books
    module Search
      # Divides a query's score by sqrt(similarity_category_count), clamped from
      # below by `floor`, so a heavily tagged book cannot win by volume. Shared by
      # BookSimilar and BookRecommendations; the reasoning for the sqrt, the floor
      # and the guard lives with BookSimilar.wrap_in_normalization.
      #
      # A missing doc value and a present-but-zero count both divide by 1 rather
      # than by sqrt(0), which would be Infinity and clamp to Float::MAX_VALUE.
      module CategoryCountNormalization
        SOURCE = "def count = doc['similarity_category_count'].size() == 0 ? 1 : doc['similarity_category_count'].value; if (count < params.floor) { count = params.floor; } return _score / Math.sqrt(count < 1 ? 1 : count);"

        module_function

        def wrap(query, floor:)
          {
            function_score: {
              query: query,
              script_score: {
                script: {
                  source: SOURCE,
                  params: {floor: floor.to_i}
                }
              },
              boost_mode: "replace"
            }
          }
        end
      end
    end
  end
end
