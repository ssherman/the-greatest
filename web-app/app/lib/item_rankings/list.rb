# frozen_string_literal: true

module ItemRankings
  class List
    include WeightedListRank::List
    attr_reader :id, :weight, :items

    def initialize(id, weight, items)
      @id = id
      @weight = weight
      @items = items
    end
  end
end
