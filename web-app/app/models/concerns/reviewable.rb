# frozen_string_literal: true

# The contract generic review code depends on. Reviews are polymorphic through
# `reviewable` and there is no per-domain Review subclass to hang behaviour on,
# so each reviewable class declares what the shared code needs from it.
#
# Every method raises on the base: a reviewable that half-implements the contract
# must fail loudly at the first call rather than render a page with no covers or
# an unsortable column.
module Reviewable
  extend ActiveSupport::Concern

  included do
    has_many :reviews, as: :reviewable, dependent: :destroy
    has_one :review_summary, as: :reviewable, dependent: :destroy
  end

  class_methods do
    # Associations to eager-load on each row of /my/reviews, so a 25-row page
    # rendering a cover and a creator each stays N+1-free.
    def review_row_includes
      raise NotImplementedError, "#{name} must override .review_row_includes"
    end

    # SQL expression the A-Z sort orders by. An expression rather than a column
    # name because a sort title is usually nullable and has to fall back.
    def review_title_order
      raise NotImplementedError, "#{name} must override .review_title_order"
    end

    # Applies a free-text filter to a Review scope already joined to this class's
    # table. Implementations MUST NOT add a join that can multiply rows -- use an
    # EXISTS subquery for has_many sides, or one book with three reviews and two
    # authors returns six rows.
    def review_text_search(scope, term)
      raise NotImplementedError, "#{name} must override .review_text_search"
    end

    # Supplies default_primary for the "site rank" sort. An implementation may
    # return nil to declare it has no site ranking -- that is an explicit answer,
    # and the sort is then not offered at all.
    def ranking_configuration_class
      raise NotImplementedError, "#{name} must override .ranking_configuration_class"
    end
  end
end
