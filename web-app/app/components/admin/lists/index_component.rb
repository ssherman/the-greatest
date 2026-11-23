# frozen_string_literal: true

class Admin::Lists::IndexComponent < ViewComponent::Base
  def initialize(lists:, pagy:, domain_config:, selected_status:, search_query:, selected_submitted: nil, selected_audit: nil, selected_items_need_revision: false)
    @lists = lists
    @pagy = pagy
    @domain_config = domain_config
    @selected_status = selected_status
    @search_query = search_query
    @selected_submitted = selected_submitted
    @selected_audit = selected_audit
    @selected_items_need_revision = selected_items_need_revision
  end

  private

  attr_reader :lists, :pagy, :domain_config, :selected_status, :selected_submitted, :selected_audit, :selected_items_need_revision, :search_query
end
