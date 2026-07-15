require "test_helper"

class Admin::EditListItemModalComponentTest < ViewComponent::TestCase
  test "renders a single empty dialog with a turbo frame" do
    render_inline(Admin::EditListItemModalComponent.new)

    assert_selector "dialog##{Admin::EditListItemModalComponent::DIALOG_ID}", count: 1
    assert_selector "turbo-frame##{Admin::EditListItemModalComponent::FRAME_ID}", count: 1
    assert_no_selector "form[action]"
  end
end
