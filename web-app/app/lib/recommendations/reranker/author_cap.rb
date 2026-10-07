# frozen_string_literal: true

module Recommendations
  module Reranker
    # At most max_per_author books per author, in fused order. Skipped, not
    # demoted: an author's other books genuinely score well, and only a cap
    # stops them filling the page (same reasoning as Services::Books::SimilarBooks).
    module AuthorCap
      def self.call(candidates, facts:, config:)
        max = config[:max_per_author].to_i
        counts = Hash.new(0)
        candidates.select do |candidate|
          authors = facts[candidate.item_id]&.author_ids || []
          next true if authors.empty?
          next false if authors.any? { |id| counts[id] >= max }

          authors.each { |id| counts[id] += 1 }
          true
        end
      end
    end
  end
end
