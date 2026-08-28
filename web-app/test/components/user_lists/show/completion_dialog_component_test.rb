# frozen_string_literal: true

require "test_helper"

class UserLists::Show::CompletionDialogComponentTest < ViewComponent::TestCase
  test "renders an accessible PATCH dialog with the completion-date controls" do
    render_inline(UserLists::Show::CompletionDialogComponent.new)

    assert_selector "dialog#completion-date-dialog[data-controller='user-list-completion'][aria-labelledby='completion-date-dialog-title']"
    assert_selector "#completion-date-dialog h2#completion-date-dialog-title", text: "Edit completion date"
    assert_selector "#completion-date-dialog form[data-user-list-completion-target='form'] input[type='hidden'][name='_method'][value='patch']", visible: :all
    assert_selector "#completion-date-dialog label", text: "Completion date"
    assert_selector "#completion-date-dialog input[type='date'][name='user_list_item[completed_on]'][data-user-list-completion-target='date']"
    assert_selector "#completion-date-dialog button[type='submit']", text: "Save"
    assert_selector "#completion-date-dialog button[data-action='user-list-completion#clear']", text: "Clear date"
    assert_selector "#completion-date-dialog button[data-action='user-list-completion#cancel']", text: "Cancel"
  end
end
