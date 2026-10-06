# frozen_string_literal: true

class Wizard::Core::ReviewStepComponent < ViewComponent::Base
  FILTER_LABELS = {"flagged" => "Flagged", "all" => "All rows", "create" => "To create", "ai" => "AI-decided"}.freeze
  COUNT_LABELS = {"matched" => "Matched", "create" => "To create", "flagged" => "Flagged", "settled" => "Settled"}.freeze

  def initialize(list:, adapter:, filter:, page: 1)
    @list = list
    @adapter = adapter
    @review = ::Services::Lists::Wizard::Core::ReviewRows.new(list: list, filter: filter, page: page, listable_includes: adapter.listable_includes)
  end

  def filter = @review.filter

  def rows = @rows ||= @review.rows

  def counts = @counts ||= ::Services::Lists::Wizard::Core::Summary.new(@list).review_counts

  def filter_path(name) = @adapter.wizard_path(:step, @list, step: "review", filter: name)

  def paged? = @review.pages > 1

  # Pagy builds its links from the request, so the filter parameter rides along
  # with the page number.
  def pagination_nav
    Pagy::Offset.new(count: @review.total, page: @review.page, limit: @review.per_page, request: request).series_nav
  end

  private

  attr_reader :list, :adapter
end
