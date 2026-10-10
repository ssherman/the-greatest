# frozen_string_literal: true

require "test_helper"

module Recommendations
  class InteractionTest < ActiveSupport::TestCase
    def interaction(kind:, rating: nil, weight: 1.0)
      Interaction.new(item_id: 1, weight: weight, kind: kind, rating: rating)
    end

    test "list positives are trainable regardless of rating" do
      assert interaction(kind: :favorite).trainable?(min_rating: 3)
      assert interaction(kind: :read).trainable?(min_rating: 3)
      assert interaction(kind: :reading).trainable?(min_rating: 3)
      assert interaction(kind: :read, rating: 1, weight: -1.1).trainable?(min_rating: 3), "a low rating on a read book is still a shelf presence"
    end

    test "want-to-read is never trainable, even with a positive weight" do
      assert_not interaction(kind: :want_to_read, weight: 0.2).trainable?(min_rating: 3)
      assert interaction(kind: :want_to_read, rating: 4).trainable?(min_rating: 3), "unless it is also rated at the floor"
    end

    test "a bare review is trainable only at or above the floor" do
      assert interaction(kind: :review, rating: 3).trainable?(min_rating: 3)
      assert_not interaction(kind: :review, rating: 2).trainable?(min_rating: 3)
      assert_not interaction(kind: :review).trainable?(min_rating: 3), "a text-only review says nothing about taste"
    end
  end
end
