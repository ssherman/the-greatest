# frozen_string_literal: true

module Recommendations
  # One book the user has touched. kind is the strongest LIST relationship
  # (:favorite > :reading/:read > :want_to_read) or :review when the book is only
  # reviewed; rating is the numeric star rating or nil. weight is already signed
  # (spec §6.1), so consumers never recompute it.
  Interaction = Struct.new(:item_id, :weight, :kind, :rating, keyword_init: true) do
    def positive? = weight.positive?

    def negative? = weight.negative?
  end
end
