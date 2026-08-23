# frozen_string_literal: true

require "test_helper"

class Admin::Music::Songs::Wizard::SharedModalComponentTest < ViewComponent::TestCase
  test "renders dialog element with correct id" do
    render_inline(Admin::Music::Songs::Wizard::SharedModalComponent.new)

    assert_selector "dialog##{Admin::Music::Songs::Wizard::SharedModalComponent::DIALOG_ID}"
  end

  test "renders turbo frame with correct id" do
    render_inline(Admin::Music::Songs::Wizard::SharedModalComponent.new)

    assert_selector "turbo-frame##{Admin::Music::Songs::Wizard::SharedModalComponent::FRAME_ID}"
  end

  test "renders with shared-modal stimulus controller" do
    render_inline(Admin::Music::Songs::Wizard::SharedModalComponent.new)

    assert_selector "dialog[data-controller='shared-modal']"
  end

  test "opens the dialog when the turbo frame loads" do
    render_inline(Admin::Music::Songs::Wizard::SharedModalComponent.new)

    assert_selector "dialog[data-action='turbo:frame-load->shared-modal#open']"
  end

  test "renders loading spinner" do
    render_inline(Admin::Music::Songs::Wizard::SharedModalComponent.new)

    assert_selector ".loading.loading-spinner"
  end

  test "renders backdrop form for closing" do
    render_inline(Admin::Music::Songs::Wizard::SharedModalComponent.new)

    assert_selector "form.modal-backdrop[method='dialog']"
  end

  test "constants are defined correctly" do
    assert_equal "shared_modal_dialog", Admin::Music::Songs::Wizard::SharedModalComponent::DIALOG_ID
    assert_equal "shared_modal_content", Admin::Music::Songs::Wizard::SharedModalComponent::FRAME_ID
    assert_equal "shared_modal_error", Admin::Music::Songs::Wizard::SharedModalComponent::ERROR_ID
  end
end
