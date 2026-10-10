# frozen_string_literal: true

module Recommendations
  # The collaborative score (spec 2 §6 step 2): for every neighbour of the
  # user's shelf, the sum of the stored weights, plus the shelf book that
  # contributed most (the "because you loved" candidate) and its weight. One
  # GROUP BY through the (model, item) index; a 200-book shelf touches at most
  # 10,000 rows. Domain-agnostic: the table carries no domain, the model does.
  module NeighborScores
    def self.call(model:, shelf_ids:, excluded_ids:, limit:)
      return [] if shelf_ids.empty?

      scope = RecommendationItemNeighbor.where(recommendation_model_id: model.id, item_id: shelf_ids)
      scope = scope.where.not(neighbor_id: excluded_ids) if excluded_ids.any?
      scope.group(:neighbor_id)
        .order(Arel.sql("SUM(weight) DESC, neighbor_id ASC"))
        .limit(limit)
        .pluck(:neighbor_id, Arel.sql("SUM(weight)"), Arel.sql("(ARRAY_AGG(item_id ORDER BY weight DESC, item_id ASC))[1]"), Arel.sql("MAX(weight)"))
        .map { |id, score, because_of, term| {item_id: id, score: score.to_f, because_of: because_of, term: term.to_f} }
    end
  end
end
