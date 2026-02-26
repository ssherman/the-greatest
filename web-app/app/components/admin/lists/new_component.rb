# frozen_string_literal: true

class Admin::Lists::NewComponent < ViewComponent::Base
  def initialize(list:, domain_config:)
    @list = list
    @domain_config = domain_config
  end

  private

  attr_reader :list, :domain_config
end
