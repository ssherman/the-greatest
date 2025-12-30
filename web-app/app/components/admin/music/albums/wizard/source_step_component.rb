# frozen_string_literal: true

# Album-specific source step component.
# Inherits shared logic from BaseSourceStepComponent.
#
class Admin::Music::Albums::Wizard::SourceStepComponent < Admin::Music::Wizard::BaseSourceStepComponent
  private

  def advance_step_path
    helpers.advance_step_admin_albums_list_wizard_path(list_id: list.id, step: "source")
  end

  def entity_name
    "album"
  end
end
