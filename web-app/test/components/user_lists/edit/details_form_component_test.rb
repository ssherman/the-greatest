# frozen_string_literal: true

require "test_helper"

class UserLists::Edit::DetailsFormComponentTest < ViewComponent::TestCase
  test "a custom list has an editable name" do
    render_inline(UserLists::Edit::DetailsFormComponent.new(user_list: user_lists(:regular_user_custom_albums)))

    assert_selector "section#list-details form"
    assert_selector "input[name='user_list[name]']:not([disabled])"
    assert_no_text "Built-in lists keep their names."
  end

  test "a default list locks the name and says why" do
    render_inline(UserLists::Edit::DetailsFormComponent.new(user_list: user_lists(:regular_user_music_albums_favorites)))

    assert_selector "input[name='user_list[name]'][disabled]"
    assert_text "Built-in lists keep their names."
  end

  test "has an errors target, description, visibility and Save" do
    render_inline(UserLists::Edit::DetailsFormComponent.new(user_list: user_lists(:regular_user_custom_albums)))

    assert_selector "#list-details-errors"
    assert_selector "textarea[name='user_list[description]']"
    assert_selector "input[type=checkbox][name='user_list[public]']"
    assert_button "Save"
  end
end
