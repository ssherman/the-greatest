# frozen_string_literal: true

# Album-specific import step component.
# Inherits shared logic from BaseImportStepComponent.
#
class Admin::Music::Albums::Wizard::ImportStepComponent < Admin::Music::Wizard::BaseImportStepComponent
  private

  def step_status_path
    helpers.step_status_admin_albums_list_wizard_path(list_id: list.id, step: "import")
  end

  def advance_step_path
    helpers.advance_step_admin_albums_list_wizard_path(list_id: list.id, step: "import")
  end

  def step_path
    helpers.step_admin_albums_list_wizard_path(list_id: list.id, step: "import")
  end

  def enrichment_id_key
    "mb_release_group_id"
  end

  def entity_name
    "album"
  end

  def entity_name_plural
    "albums"
  end
end
