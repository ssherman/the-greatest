# frozen_string_literal: true

module ItemRankings
  class Item
    include WeightedListRank::Item

    attr_reader :id, :position, :score_penalty

    def initialize(id, position, score_penalty = nil)
      @id = id
      @position = position
      @score_penalty = score_penalty
    end
  end
end
