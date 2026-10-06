# frozen_string_literal: true

class Wizard::Core::ReviewRowComponent < ViewComponent::Base
  BADGES = {"matched" => "badge-success", "create" => "badge-info", "flagged" => "badge-warning"}.freeze

  attr_reader :filter

  def initialize(row:, list:, adapter:, filter:, page: nil)
    @row = row
    @list = list
    @adapter = adapter
    @filter = filter
    @page = (page.to_i > 1) ? page.to_i : nil
  end

  def item = @row.item

  def state = @row.state

  def candidates = @row.candidates

  def row_text = @row_text ||= @adapter.row_display(item)

  def linked = item.listable && @adapter.record_display(item.listable)

  def reasons = state.reasons.map { |reason| ::Services::Lists::Wizard::Core::RowState.label_for(reason) }

  def problem = state.import_error.presence || state.error.presence

  def bucket_badge = BADGES.fetch(state.bucket.to_s, "badge-ghost")

  def bucket_label = state.bucket.to_s.humanize.presence || "Not in the wizard"

  def search_path = @adapter.search_path

  def search_id = "row_#{item.id}_record"

  def field_id(name) = "row_#{item.id}_#{name}"

  # The page rides in the query string, so an action sends the admin back to it.
  def path(name) = @adapter.wizard_path(name, @list, **{row_id: item.id, page: @page}.compact)
end
