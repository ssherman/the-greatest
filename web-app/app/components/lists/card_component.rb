# frozen_string_literal: true

class Lists::CardComponent < ViewComponent::Base
  def initialize(ranked_list:, item_count:, path:, noun:)
    @ranked_list = ranked_list
    @item_count = item_count
    @path = path
    @noun = noun
  end

  private

  attr_reader :ranked_list, :item_count, :path, :noun

  def list
    @list ||= ranked_list.list
  end

  def weight
    ranked_list.weight
  end

  def source_line
    year = list.yearly_award? ? "Yearly Award" : list.year_published
    [list.source.presence, year.presence].compact.join(" · ")
  end

  def added_ago
    return nil if list.activated_at.blank?
    "added #{time_ago_in_words(list.activated_at)} ago"
  end
end
