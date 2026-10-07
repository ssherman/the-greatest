# frozen_string_literal: true

require "test_helper"

class Admin::Lists::ShowComponentTest < ViewComponent::TestCase
  include ListWizardHelper

  test "unlinked_rows_count counts rows with no book, leaving out removed rows" do
    list = wizard_list
    wizard_row(list, position: 1, title: "Linked", listable: books_books(:got), wizard: {bucket: "matched"})
    wizard_row(list, position: 2, title: "Unlinked", wizard: {bucket: "flagged"})
    wizard_row(list, position: 3, title: "Removed", wizard: {bucket: "removed", settled: true})

    component = Admin::Lists::ShowComponent.new(list: list, domain_config: {})
    assert_equal 1, component.unlinked_rows_count
    assert component.show_unlinked_rows?
  end

  test "a books list with no unlinked rows hides the count" do
    list = wizard_list
    wizard_row(list, position: 1, title: "Linked", listable: books_books(:got), wizard: {bucket: "matched"})

    assert_not Admin::Lists::ShowComponent.new(list: list, domain_config: {}).show_unlinked_rows?
  end

  test "the unlinked count is not shown on games lists" do
    games = lists(:games_list)
    games.list_items.destroy_all
    games.list_items.create!(listable_type: "Games::Game", position: 1, metadata: {"title" => "Hades"})

    assert_not Admin::Lists::ShowComponent.new(list: games, domain_config: {}).show_unlinked_rows?
  end

  def render_show(list)
    config = {
      item_label: "Item", item_label_plural: "Items", lists_path: "/lists",
      list_path_proc: ->(l) { "/lists/#{l.id}" }, new_list_path: "/lists/new",
      edit_list_path_proc: ->(l) { "/lists/#{l.id}/edit" },
      wizard_path_proc: ->(l) { "/lists/#{l.id}/wizard" },
      items_count_method: "items_count", extra_fields: [], extra_show_fields: []
    }
    vc_test_controller.view_context_class.send(:define_method, :current_user_can_write?) { true }
    with_request_url("/admin/lists/#{list.id}", host: Rails.application.config.domains[:books]) do
      render_inline(Admin::Lists::ShowComponent.new(list: list, domain_config: config))
    end
  end

  test "renders the unlinked stat with its count on a books list that has unlinked rows" do
    list = wizard_list
    wizard_row(list, position: 1, title: "Linked", listable: books_books(:got), wizard: {bucket: "matched"})
    wizard_row(list, position: 2, title: "Unlinked", wizard: {bucket: "flagged"})
    render_show(list)

    assert_selector "[data-stat=unlinked]", count: 1
    assert_selector "[data-stat=unlinked] .stat-value", text: /\A1\z/
  end

  test "renders no unlinked stat on a books list whose rows are all linked" do
    list = wizard_list
    wizard_row(list, position: 1, title: "Linked", listable: books_books(:got), wizard: {bucket: "matched"})
    render_show(list)

    assert_no_selector "[data-stat=unlinked]"
  end

  test "renders no unlinked stat on a games list with an unlinked row" do
    games = lists(:games_list)
    games.list_items.destroy_all
    games.list_items.create!(listable_type: "Games::Game", position: 1, metadata: {"title" => "Hades"})
    render_show(games)

    assert_no_selector "[data-stat=unlinked]"
  end

  test "the unlinked stat links to the Review step with every row shown, not just the flagged ones" do
    list = wizard_list
    wizard_row(list, position: 1, title: "Unlinked", wizard: {bucket: "flagged"})
    render_show(list)

    href = page.find("[data-stat=unlinked] a")[:href]
    assert_equal ["/lists/#{list.id}/wizard/step/review", "all"], [URI(href).path, Rack::Utils.parse_query(URI(href).query)["filter"]]
  end
end
