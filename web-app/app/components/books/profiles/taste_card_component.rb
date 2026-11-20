# frozen_string_literal: true

# Favourite genres as bars scaled to the strongest, favourite subjects as
# badges. Below the minimum an owner is told how far along they are.
class Books::Profiles::TasteCardComponent < ViewComponent::Base
  def initialize(taste:, audience:)
    @taste = taste
    @audience = audience
  end

  def render?
    ready? || owner?
  end

  private

  attr_reader :taste, :audience

  def owner? = audience == :owner

  def ready? = !taste.nil? && taste.ready

  def minimum = Services::Books::Profiles::Taste::MIN_BOOKS

  def qualifying_count = taste&.qualifying_count.to_i

  def category_path(category)
    Books::FilterPath.call(categories: [category])
  end

  def bar_value(weight)
    (weight * 100).round
  end
end
