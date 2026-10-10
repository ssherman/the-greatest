# frozen_string_literal: true

module Recommendations
  module Signals
    # Readers-like-you (spec 2 §6). Scores the user's trainable shelf against
    # the active model's neighbour rows, passes the best ids through the
    # ranked-pool query so every setting applies, and names the loved book
    # that contributed most. Unavailable without an active model for the
    # domain, or when `collaborative` is switched off (the harness's
    # taste-only variant).
    class Collaborative < Base
      def available?
        config[:collaborative] && !model.nil?
      end

      def weight(positive_count)
        n = positive_count.to_f
        n / (n + config[:collaborative_half_point])
      end

      def call(profile:, interactions:, criteria:, excluded_ids:, size:)
        shelf = interactions.select { |i| i.trainable?(min_rating: config[:collaborative_min_rating]) }
        return [] if shelf.empty? || model.nil?

        scored = NeighborScores.call(model: model, shelf_ids: shelf.map(&:item_id).uniq, excluded_ids: excluded_ids,
          limit: size * config[:collaborative_overfetch].to_i)
        return [] if scored.empty?

        kept = adapter.filter_candidate_ids(scored.map { |row| row[:item_id] }, criteria: criteria, excluded_ids: excluded_ids)
        loved = shelf.select { |i| i.kind == :favorite || (i.rating && i.rating >= config[:because_of_rating]) }.map(&:item_id).to_set

        scored.select { |row| kept.key?(row[:item_id]) }.first(size).map do |row|
          evidence = {term: row[:term]}
          evidence[:because_of] = row[:because_of] if loved.include?(row[:because_of])
          Candidate.new(item_id: row[:item_id], score: row[:score], rank_position: kept[row[:item_id]], evidence: evidence)
        end
      end

      private

      def model
        return @model if defined?(@model)

        @model = RecommendationModel.active_for(adapter.domain)
      end
    end
  end
end
