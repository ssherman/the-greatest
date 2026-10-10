# frozen_string_literal: true

module Recommendations
  # One book the user has touched. kind is the strongest LIST relationship
  # (:favorite > :reading/:read > :want_to_read) or :review when the book is only
  # reviewed; rating is the numeric star rating or nil. weight is already signed
  # (spec §6.1), so consumers never recompute it.
  Interaction = Struct.new(:item_id, :weight, :kind, :rating, keyword_init: true) do
    def positive? = weight.positive?

    def negative? = weight.negative?

    # A positive for the collaborative model (spec 2 §3): a shelf presence or
    # a rating at the floor. Same predicate as Books::PositivePairs's SQL; the
    # pairs test asserts the two agree. Not the signed weight: want-to-read is
    # weighted positive but is not a positive here.
    def trainable?(min_rating:)
      Interaction::TRAINABLE_KINDS.include?(kind) || (!rating.nil? && rating >= min_rating)
    end
  end

  # Declared outside the Struct block: a constant defined in a block lands in
  # the enclosing lexical scope, not on the struct.
  Interaction::TRAINABLE_KINDS = %i[favorite read reading].freeze
end
