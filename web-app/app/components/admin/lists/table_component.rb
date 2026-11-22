# frozen_string_literal: true

class Admin::Lists::TableComponent < ViewComponent::Base
  def initialize(lists:, pagy:, domain_config:, search_query:)
    @lists = lists
    @pagy = pagy
    @domain_config = domain_config
    @search_query = search_query
  end

  private

  attr_reader :lists, :pagy, :domain_config, :search_query

  def sort_path(column, direction)
    domain_config[:lists_path] + "?" + {
      sort: column,
      direction: direction,
      status: helpers.params[:status],
      submitted: helpers.params[:submitted],
      audit: helpers.params[:audit],
      q: helpers.params[:q]
    }.compact.to_query
  end

  def audits?
    domain_config[:list_audits]
  end

  # The most recent finished audit per list on this page, in one query.
  def last_audit(list)
    @last_audits ||= ::ListAudit.finished.where(list_id: lists.map(&:id)).order(:finished_at).index_by(&:list_id)
    @last_audits[list.id]
  end

  def items_count(list)
    list.public_send(domain_config[:items_count_method])
  end
end
