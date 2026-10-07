# frozen_string_literal: true

module Recommendations
  # type is :because_of (ids = [item_id]), :interests (ids = category ids), or
  # :ranked (ids = [rank_position]). Structured so a later API can return it.
  Reason = Struct.new(:type, :ids, keyword_init: true)
end
