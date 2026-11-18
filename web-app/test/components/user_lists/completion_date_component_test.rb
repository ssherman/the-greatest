# frozen_string_literal: true

require "test_helper"

class UserLists::CompletionDateComponentTest < ViewComponent::TestCase
  Component = UserLists::CompletionDateComponent

  test "table variant for the owner with no date offers Add date" do
    item = user_list_items(:regular_user_books_item_3)
    item.completed_on = nil
    render_inline(Component.new(item: item, variant: :table, editable: true))

    assert_selector "button.link[aria-label='Finished date for #{item.listable.title}: Add date'][data-variant='table']", text: "Add date"
  end

  test "table variant shows the date on the trigger" do
    item = user_list_items(:regular_user_books_item_3)
    render_inline(Component.new(item: item, variant: "table", editable: true))

    assert_selector "button.link[data-completed-on='2026-01-20']", text: "Jan 20, 2026"
  end

  test "table variant without editable is plain text" do
    item = user_list_items(:regular_user_books_item_3)
    render_inline(Component.new(item: item, variant: :table))

    assert_no_selector "button"
    assert_text "Jan 20, 2026"
  end

  test "text variant shows the label and date" do
    item = user_list_items(:regular_user_books_item_3)
    render_inline(Component.new(item: item, variant: "text"))

    assert_text "Finished Jan 20, 2026"
  end

  test "text variant renders nothing visible without a date" do
    item = user_list_items(:regular_user_books_item_3)
    item.completed_on = nil
    render_inline(Component.new(item: item, variant: :text))

    assert_no_text(/\S/)
  end

  test "the date trigger's accessible name includes its visible date" do
    item = user_list_items(:regular_user_books_item_3)
    render_inline(Component.new(item: item, variant: :table, editable: true))

    assert_selector "button[aria-label='Finished date for #{item.listable.title}: Jan 20, 2026']", text: "Jan 20, 2026"
  end

  test "row variant shows the placeholder without a date" do
    item = user_list_items(:regular_user_books_item_3)
    item.completed_on = nil
    render_inline(Component.new(item: item, variant: :row))

    assert_selector "p[id='#{ActionView::RecordIdentifier.dom_id(item, :completion)}']", text: "No finished date"
  end

  test "row variant shows the label and date when set" do
    item = user_list_items(:regular_user_books_item_3)
    render_inline(Component.new(item: item, variant: "row"))

    assert_text "Finished Jan 20, 2026"
    assert_no_text "No finished date"
  end

  test "an unknown variant falls back to table" do
    item = user_list_items(:regular_user_books_item_3)
    render_inline(Component.new(item: item, variant: "bogus", editable: true))

    assert_selector "button.link"
  end

  test "root id is the item's completion dom id" do
    item = user_list_items(:regular_user_books_item_3)
    render_inline(Component.new(item: item, variant: :text))

    assert_selector "##{ActionView::RecordIdentifier.dom_id(item, :completion)}"
  end

  test "single-digit days are not zero-padded" do
    item = user_list_items(:regular_user_books_item_3)
    item.completed_on = Date.new(2026, 3, 3)
    render_inline(Component.new(item: item, variant: :text))

    assert_text "Finished Mar 3, 2026"
  end
end
