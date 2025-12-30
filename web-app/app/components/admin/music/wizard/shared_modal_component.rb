# frozen_string_literal: true

# Shared modal component that renders a single <dialog> element with a Turbo Frame.
# Modal content is loaded on-demand when action buttons are clicked.
# This replaces per-item modal rendering to improve performance with large lists.
#
# Domain-specific subclasses (Songs, Albums) inherit from this base class.
# All constants (DIALOG_ID, FRAME_ID, ERROR_ID) are defined here and inherited.
#
# Usage:
#   <%= render(Admin::Music::Songs::Wizard::SharedModalComponent.new) %>
#   or
#   <%= render(Admin::Music::Albums::Wizard::SharedModalComponent.new) %>
#
# Action buttons should link to the modal endpoint with data-turbo-frame:
#   <%= link_to "Edit Metadata",
#       modal_path(item, :edit_metadata),
#       data: { turbo_frame: Admin::Music::Songs::Wizard::SharedModalComponent::FRAME_ID } %>
class Admin::Music::Wizard::SharedModalComponent < ViewComponent::Base
  DIALOG_ID = "shared_modal_dialog"
  FRAME_ID = "shared_modal_content"
  ERROR_ID = "shared_modal_error"

  def dialog_id
    DIALOG_ID
  end

  def frame_id
    FRAME_ID
  end

  def error_id
    ERROR_ID
  end
end
