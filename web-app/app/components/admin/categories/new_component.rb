# frozen_string_literal: true

class Admin::Categories::NewComponent < ViewComponent::Base
  def initialize(category:, domain_config:)
    @category = category
    @domain_config = domain_config
  end

  private

  attr_reader :category, :domain_config
end
