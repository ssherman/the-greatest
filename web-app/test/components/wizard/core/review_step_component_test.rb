# frozen_string_literal: true

require "test_helper"

class Wizard::Core::ReviewStepComponentTest < ViewComponent::TestCase
  include ListWizardHelper

  setup do
    @list = wizard_list
    @adapter = ::Services::Lists::Wizard::Books::Adapter.new
    wizard_row(@list, position: 1, title: "Matched", listable: books_books(:war_and_peace), wizard: {bucket: "matched"})
    wizard_row(@list, position: 2, title: "Flagged", wizard: {bucket: "flagged", reasons: ["not_found"]})
    wizard_row(@list, position: 3, title: "Create", wizard: {bucket: "create"})
  end

  test "the default view shows only flagged rows, with the counts and a link per filter" do
    render_inline(Wizard::Core::ReviewStepComponent.new(list: @list, adapter: @adapter, filter: "flagged"))

    assert_selector "[data-testid=review-row]", count: 1
    assert_selector "[data-testid=review-counts] [data-stat=matched] .stat-value", text: "1"
    %w[flagged all create ai].each do |filter|
      assert_selector "a[role=tab][href='#{@adapter.wizard_path(:step, @list, step: "review", filter: filter)}']"
    end
    assert_selector "a.tab-active[href*='filter=flagged']"
  end

  test "the all filter shows every row, and an empty view says so" do
    render_inline(Wizard::Core::ReviewStepComponent.new(list: @list, adapter: @adapter, filter: "all"))
    assert_selector "[data-testid=review-row]", count: 3

    render_inline(Wizard::Core::ReviewStepComponent.new(list: @list, adapter: @adapter, filter: "ai"))
    assert_selector "[data-testid=review-row]", count: 0
    assert_selector "[data-testid=review-empty]"
  end

  test "a long view is paged at 100 rows, with a nav only when there is more than one page" do
    list = wizard_list
    (1..102).each { |n| wizard_row(list, position: n, title: "Row #{n}", wizard: {bucket: "flagged"}) }

    render_inline(Wizard::Core::ReviewStepComponent.new(list: list, adapter: @adapter, filter: "flagged"))
    assert_selector "[data-testid=review-row]", count: 100
    assert_selector "[data-testid=review-pagination]"

    render_inline(Wizard::Core::ReviewStepComponent.new(list: list, adapter: @adapter, filter: "flagged", page: 2))
    assert_selector "[data-testid=review-row]", count: 2

    render_inline(Wizard::Core::ReviewStepComponent.new(list: @list, adapter: @adapter, filter: "all"))
    assert_no_selector "[data-testid=review-pagination]"
  end

  test "an out-of-range page shows the last page rather than failing" do
    render_inline(Wizard::Core::ReviewStepComponent.new(list: @list, adapter: @adapter, filter: "all", page: 40))
    assert_selector "[data-testid=review-row]", count: 3
  end
end
