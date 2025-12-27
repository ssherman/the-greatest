# frozen_string_literal: true

# Shared modal component that renders a single <dialog> element with a Turbo Frame.
# Modal content is loaded on-demand when action buttons are clicked.
# This replaces per-item modal rendering to improve performance with large lists.
#
# Usage:
#   <%= render(Admin::Music::Songs::Wizard::SharedModalComponent.new) %>
#
# Action buttons should link to the modal endpoint with data-turbo-frame:
#   <%= link_to "Edit Metadata",
#       modal_admin_songs_list_item_path(@list, item, modal_type: :edit_metadata),
#       data: { turbo_frame: "shared_modal_content" } %>
class Admin::Music::Songs::Wizard::SharedModalComponent < ViewComponent::Base
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
