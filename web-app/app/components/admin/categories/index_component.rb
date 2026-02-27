# frozen_string_literal: true

class Admin::Categories::IndexComponent < ViewComponent::Base
  def initialize(categories:, pagy:, domain_config:)
    @categories = categories
    @pagy = pagy
    @domain_config = domain_config
  end

  private

  attr_reader :categories, :pagy, :domain_config
end
