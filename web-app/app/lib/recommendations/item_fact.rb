# frozen_string_literal: true

module Recommendations
  ItemFact = Struct.new(:author_ids, :genre_ids, :series_predecessor_id, :rank_position, keyword_init: true)
end
