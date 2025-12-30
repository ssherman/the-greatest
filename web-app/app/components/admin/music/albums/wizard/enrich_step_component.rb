# frozen_string_literal: true

# Album-specific enrich step component.
# Inherits shared logic from BaseEnrichStepComponent.
#
class Admin::Music::Albums::Wizard::EnrichStepComponent < Admin::Music::Wizard::BaseEnrichStepComponent
  private

  def step_status_path
    helpers.step_status_admin_albums_list_wizard_path(list_id: list.id, step: "enrich")
  end

  def advance_step_path
    helpers.advance_step_admin_albums_list_wizard_path(list_id: list.id, step: "enrich")
  end

  def reenrich_path
    helpers.advance_step_admin_albums_list_wizard_path(list_id: list.id, step: "enrich", reenrich: true)
  end

  def step_path
    helpers.step_admin_albums_list_wizard_path(list_id: list.id, step: "enrich")
  end

  def entity_name
    "album"
  end

  def entity_name_plural
    "albums"
  end
end
