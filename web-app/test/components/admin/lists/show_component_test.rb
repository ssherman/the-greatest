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
end
