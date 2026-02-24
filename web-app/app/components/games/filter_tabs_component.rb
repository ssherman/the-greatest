# frozen_string_literal: true

class Games::FilterTabsComponent < ViewComponent::Base
  DECADES = %w[1980s 1990s 2000s 2010s 2020s].freeze

  def initialize(base_path:, year_filter:)
    @base_path = base_path
    @year_filter = year_filter
  end

  private

  attr_reader :base_path, :year_filter

  def decades
    DECADES
  end

  def all_time_active?
    year_filter.nil?
  end

  def decade_active?(decade)
    return false unless year_filter
    year_filter.type == :decade && year_filter.display == decade
  end

  def custom_active?
    return false unless year_filter
    %i[range single since through].include?(year_filter.type)
  end

  def tab_class(active:)
    base = "tab whitespace-nowrap"
    active ? "#{base} tab-active" : base
  end

  def decade_path(decade)
    "#{base_path}/#{decade}"
  end
end
