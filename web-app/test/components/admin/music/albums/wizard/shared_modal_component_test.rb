# frozen_string_literal: true

require "test_helper"

class Admin::Music::Albums::Wizard::SharedModalComponentTest < ViewComponent::TestCase
  test "renders dialog element with correct id" do
    render_inline(Admin::Music::Albums::Wizard::SharedModalComponent.new)

    assert_selector "dialog##{Admin::Music::Albums::Wizard::SharedModalComponent::DIALOG_ID}"
  end

  test "renders turbo frame with correct id" do
    render_inline(Admin::Music::Albums::Wizard::SharedModalComponent.new)

    assert_selector "turbo-frame##{Admin::Music::Albums::Wizard::SharedModalComponent::FRAME_ID}"
  end

  test "renders with shared-modal stimulus controller" do
    render_inline(Admin::Music::Albums::Wizard::SharedModalComponent.new)

    assert_selector "dialog[data-controller='shared-modal']"
  end

  test "renders loading spinner" do
    render_inline(Admin::Music::Albums::Wizard::SharedModalComponent.new)

    assert_selector ".loading.loading-spinner"
  end

  test "renders backdrop form for closing" do
    render_inline(Admin::Music::Albums::Wizard::SharedModalComponent.new)

    assert_selector "form.modal-backdrop[method='dialog']"
  end

  test "constants are defined correctly" do
    assert_equal "shared_modal_dialog", Admin::Music::Albums::Wizard::SharedModalComponent::DIALOG_ID
    assert_equal "shared_modal_content", Admin::Music::Albums::Wizard::SharedModalComponent::FRAME_ID
    assert_equal "shared_modal_error", Admin::Music::Albums::Wizard::SharedModalComponent::ERROR_ID
  end
end
