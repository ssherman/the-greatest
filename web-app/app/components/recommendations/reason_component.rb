# frozen_string_literal: true

module Recommendations
  # One line under a recommended book saying why it is there (spec §8.3).
  # `names` maps [kind, id] (kind is :category for interests, :item for
  # because_of) to a display string, since a category id and a book id can be
  # the same integer; an id with
  # no name renders as "#id" rather than raising, since a category or book
  # can disappear between the query and the page.
  class ReasonComponent < ViewComponent::Base
    def initialize(reason:, names:)
      @reason = reason
      @names = names
    end

    def text
      case @reason.type
      when :because_of
        "Because you loved #{name(:item, @reason.ids.first)}"
      when :interests
        "Matches #{@reason.ids.map { |id| name(:category, id) }.join(" and ")}"
      else
        position = @reason.ids.first
        position ? "Ranked ##{position} of all time" : "On the all-time list"
      end
    end

    private

    def name(kind, id)
      @names.fetch([kind, id]) { "##{id}" }
    end
  end
end
