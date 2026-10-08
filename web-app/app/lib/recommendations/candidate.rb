# frozen_string_literal: true

module Recommendations
  # A scored item from one signal. evidence is a Hash the explainer reads:
  # {categories: [id, ...]} from the taste signal, {because_of: item_id} from
  # the collaborative signal, {} from the rank-only fallback.
  Candidate = Struct.new(:item_id, :score, :rank_position, :evidence, keyword_init: true)
end
