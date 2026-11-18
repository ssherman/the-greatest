# frozen_string_literal: true

require "test_helper"

class UserLists::Dashboard::NewListDialogComponentTest < ViewComponent::TestCase
  Component = UserLists::Dashboard::NewListDialogComponent

  test "shows a type select labelled by listable when the domain has several types" do
    render_inline(Component.new(types: [Music::Albums::UserList, Music::Songs::UserList]))

    assert_selector "dialog#new-list-dialog"
    assert_selector "select[name='user_list[type]'] option[value='Music::Albums::UserList']"
    assert_selector "select[name='user_list[type]'] option[value='Music::Songs::UserList']"
    assert_selector "input[name='user_list[name]'][maxlength='100'][required]"
    assert_selector "textarea[name='user_list[description]'][maxlength='1000']"
    assert_selector "#new-list-errors[role='alert']"
    assert_selector "input[name='user_list[name]'][aria-label='Name']"
    assert_selector "textarea[aria-label='Description (optional)']"
    assert_selector "select[aria-label='List of']"
  end

  test "hides and pre-fills the type when the domain has one type" do
    render_inline(Component.new(types: [Games::UserList]))

    assert_no_selector "select"
    assert_selector "input[type='hidden'][name='user_list[type]'][value='Games::UserList']", visible: :all
  end
end
