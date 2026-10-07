# frozen_string_literal: true

require "test_helper"

class Wizard::Core::DoneStepComponentTest < ViewComponent::TestCase
  include ListWizardHelper

  test "shows each Done count and links back to the list" do
    list = wizard_list
    adapter = ::Services::Lists::Wizard::Books::Adapter.new
    wizard_row(list, position: 1, title: "Created", listable: books_books(:got), wizard: {bucket: "matched", import_result: "created", settled: true})
    wizard_row(list, position: 2, title: "Left", wizard: {bucket: "flagged"})

    render_inline(Wizard::Core::DoneStepComponent.new(list: list, adapter: adapter))

    assert_selector "[data-testid=done-summary] [data-stat=created] .stat-value", text: "1"
    assert_selector "[data-testid=done-summary] [data-stat=unlinked] .stat-value", text: "1"
    %w[matched admin_linked changed_since_match duplicate_pairs].each do |key|
      assert_selector "[data-testid=done-summary] [data-stat=#{key}] .stat-value", text: "0"
    end
    assert_selector "a[href='#{adapter.list_path(list)}']"
  end
end
