# frozen_string_literal: true

class Admin::EditListItemModalComponent < ViewComponent::Base
  DIALOG_ID = "edit_list_item_modal_dialog"
  FRAME_ID = "edit_list_item_modal_content"

  def dialog_id
    DIALOG_ID
  end

  def frame_id
    FRAME_ID
  end
end
