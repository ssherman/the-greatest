# frozen_string_literal: true

# Album-specific validate step component.
# Inherits shared logic from BaseValidateStepComponent.
#
class Admin::Music::Albums::Wizard::ValidateStepComponent < Admin::Music::Wizard::BaseValidateStepComponent
  private

  def step_status_path
    helpers.step_status_admin_albums_list_wizard_path(list_id: list.id, step: "validate")
  end

  def advance_step_path
    helpers.advance_step_admin_albums_list_wizard_path(list_id: list.id, step: "validate")
  end

  def revalidate_path
    helpers.advance_step_admin_albums_list_wizard_path(list_id: list.id, step: "validate", revalidate: true)
  end

  def step_path
    helpers.step_admin_albums_list_wizard_path(list_id: list.id, step: "validate")
  end

  def entity_id_key
    "album_id"
  end

  def enrichment_id_key
    "mb_release_group_id"
  end

  def entity_name
    "album"
  end
end
