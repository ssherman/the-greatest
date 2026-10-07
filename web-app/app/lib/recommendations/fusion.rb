# frozen_string_literal: true

module Recommendations
  # Weighted reciprocal-rank fusion (spec §5.4): fused = Σ w / (k + rank), rank
  # 1-based within each list. Rank-based on purpose so the OpenSearch scale and
  # (later) the collaborative scale never need reconciling. The global rank is a
  # third list built from the fused items themselves, so it can re-order what the
  # personalized signals surfaced but never introduce a book.
  class Fusion
    def self.call(lists:, config:)
      new(lists: lists, config: config).call
    end

    def initialize(lists:, config:)
      @lists = lists
      @k = config[:rrf_k].to_f
      @prior_weight = config[:rank_prior_weight].to_f
    end

    def call
      scores = Hash.new(0.0)
      merged = {}

      @lists.each do |list|
        weight = list[:weight].to_f
        list[:candidates].each_with_index do |candidate, index|
          merged[candidate.item_id] ||= Candidate.new(item_id: candidate.item_id, score: 0.0,
            rank_position: candidate.rank_position, evidence: {})
          merged[candidate.item_id].rank_position ||= candidate.rank_position
          merged[candidate.item_id].evidence.merge!(candidate.evidence || {})
          scores[candidate.item_id] += weight / (@k + index + 1) if weight.positive?
        end
      end

      apply_rank_prior(merged, scores) if @prior_weight.positive?

      merged.values.each { |c| c.score = scores[c.item_id] }
        .sort_by { |c| [-c.score, c.item_id] }
    end

    private

    def apply_rank_prior(merged, scores)
      merged.values.reject { |c| c.rank_position.nil? }
        .sort_by { |c| [c.rank_position, c.item_id] }
        .each_with_index { |c, index| scores[c.item_id] += @prior_weight / (@k + index + 1) }
    end
  end
end
