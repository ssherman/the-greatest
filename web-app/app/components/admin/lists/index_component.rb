# frozen_string_literal: true

class Admin::Lists::IndexComponent < ViewComponent::Base
  def initialize(lists:, pagy:, domain_config:, selected_status:, search_query:, selected_submitted: nil)
    @lists = lists
    @pagy = pagy
    @domain_config = domain_config
    @selected_status = selected_status
    @search_query = search_query
    @selected_submitted = selected_submitted
  end

  private

  attr_reader :lists, :pagy, :domain_config, :selected_status, :selected_submitted, :search_query
end
