# frozen_string_literal: true

class Admin::Categories::ShowComponent < ViewComponent::Base
  STAT_COLORS = %w[text-primary text-secondary text-accent].freeze

  def initialize(category:, domain_config:, stats:)
    @category = category
    @domain_config = domain_config
    @stats = stats
  end

  private

  attr_reader :category, :domain_config, :stats

  def category_path(cat)
    domain_config[:category_path_proc].call(cat)
  end

  def edit_category_path(cat)
    domain_config[:edit_category_path_proc].call(cat)
  end

  def stat_color(index)
    STAT_COLORS[index % STAT_COLORS.length]
  end
end
