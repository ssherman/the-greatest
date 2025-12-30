# frozen_string_literal: true

# Song-specific import step component.
# Inherits shared logic from BaseImportStepComponent.
#
class Admin::Music::Songs::Wizard::ImportStepComponent < Admin::Music::Wizard::BaseImportStepComponent
  private

  def step_status_path
    helpers.step_status_admin_songs_list_wizard_path(list_id: list.id, step: "import")
  end

  def advance_step_path
    helpers.advance_step_admin_songs_list_wizard_path(list_id: list.id, step: "import")
  end

  def step_path
    helpers.step_admin_songs_list_wizard_path(list_id: list.id, step: "import")
  end

  def enrichment_id_key
    "mb_recording_id"
  end

  def entity_name
    "song"
  end

  def entity_name_plural
    "songs"
  end
end
