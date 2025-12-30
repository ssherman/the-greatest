# frozen_string_literal: true

# Song-specific enrich step component.
# Inherits shared logic from BaseEnrichStepComponent.
#
class Admin::Music::Songs::Wizard::EnrichStepComponent < Admin::Music::Wizard::BaseEnrichStepComponent
  private

  def step_status_path
    helpers.step_status_admin_songs_list_wizard_path(list_id: list.id, step: "enrich")
  end

  def advance_step_path
    helpers.advance_step_admin_songs_list_wizard_path(list_id: list.id, step: "enrich")
  end

  def reenrich_path
    helpers.advance_step_admin_songs_list_wizard_path(list_id: list.id, step: "enrich", reenrich: true)
  end

  def step_path
    helpers.step_admin_songs_list_wizard_path(list_id: list.id, step: "enrich")
  end

  def entity_name
    "song"
  end

  def entity_name_plural
    "songs"
  end
end
