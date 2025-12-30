# frozen_string_literal: true

# Song-specific source step component.
# Inherits shared logic from BaseSourceStepComponent.
#
class Admin::Music::Songs::Wizard::SourceStepComponent < Admin::Music::Wizard::BaseSourceStepComponent
  private

  def advance_step_path
    helpers.advance_step_admin_songs_list_wizard_path(list_id: list.id, step: "source")
  end

  def entity_name
    "song"
  end
end
