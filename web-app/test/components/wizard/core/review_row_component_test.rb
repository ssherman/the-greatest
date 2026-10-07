# frozen_string_literal: true

require "test_helper"

class Wizard::Core::ReviewRowComponentTest < ViewComponent::TestCase
  include ListWizardHelper

  setup do
    @list = wizard_list
    @adapter = ::Services::Lists::Wizard::Books::Adapter.new
    @got = books_books(:got)
    @item = wizard_row(@list, position: 1, title: "A Game of Thrones", authors: ["George R. R. Martin"], wizard: {bucket: "flagged", reasons: ["unsure"]})
    held = ::DataImporters::Candidate.new(record: books_books(:clash), external_key: "OL7W", external_source: :open_library,
      sources: [:open_library], evidence: {title: "A Clash of Kings", creators: [], list_count: 2})
    decision = wizard_match(subject: @item, outcome: :unmatched, decided_by: :ai,
      candidates: [local_candidate(@got, list_count: 4), ol_candidate("OL9W", title: "A Game of Thrones"), held]).decision
    ::Services::Lists::Wizard::Core::RowState.new(@item).merge("match_decision_id" => decision.id)
    @item.save!
  end

  def first_row = ::Services::Lists::Wizard::Core::ReviewRows.new(list: @list, filter: "all").rows.first

  def render_row(filter: "flagged", row: first_row)
    render_inline(Wizard::Core::ReviewRowComponent.new(row: row, list: @list, adapter: @adapter, filter: filter))
  end

  def path(name) = @adapter.wizard_path(name, @list, row_id: @item.id)

  test "a local candidate can be linked, an Open Library-only one created from, a held one only linked" do
    render_row

    assert_selector "[data-testid=row-candidate]", count: 3
    assert_selector "form[action='#{path(:link_row)}'] input[name=record_id][value='#{@got.id}']", visible: :all
    assert_selector "form[action='#{path(:create_row)}'] input[name=external_key][value=OL9W]", visible: :all
    assert_selector "form[action='#{path(:link_row)}'] input[name=record_id][value='#{books_books(:clash).id}']", visible: :all
    assert_no_selector "form[action='#{path(:create_row)}'] input[name=external_key][value=OL7W]", visible: :all
  end

  test "every row offers search, create from text, edit and remove, each keeping the current filter" do
    render_row(filter: "ai")

    assert_selector "form[action='#{path(:link_row)}'] input#row_#{@item.id}_record[type=hidden][name=record_id]", visible: :all
    assert_selector "form[action='#{path(:create_row_from_text)}'] input[name=filter][value=ai]", visible: :all
    assert_selector "form[action='#{path(:edit_row)}'] input[name=title][value='A Game of Thrones']", visible: :all
    assert_selector "form[action='#{path(:edit_row)}'] textarea[name=authors]", text: "George R. R. Martin", visible: :all
    assert_selector "form[action='#{path(:remove_row)}'] input[name=filter][value=ai]", visible: :all
    assert_selector "[data-testid=row-reasons] li", count: 1
  end

  test "on a later page, every action's URL carries the page, so the admin returns to it" do
    render_inline(Wizard::Core::ReviewRowComponent.new(row: first_row, list: @list, adapter: @adapter, filter: "ai", page: 3))

    %i[link_row create_row_from_text edit_row remove_row].each do |action|
      assert_selector "form[action='#{@adapter.wizard_path(action, @list, row_id: @item.id, page: 3)}']", visible: :all
    end
  end

  test "rendering a row never asks its decision for the record or the AI chat (no per-row queries)" do
    row = first_row
    row.decision.expects(:record).never
    row.decision.expects(:ai_chat).never

    render_row(row: row)

    assert_selector "[data-testid=row-candidate]", count: 3
  end
end
