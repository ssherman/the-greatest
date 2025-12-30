# frozen_string_literal: true

# Song-specific parse step component.
# Inherits shared logic from BaseParseStepComponent.
#
class Admin::Music::Songs::Wizard::ParseStepComponent < Admin::Music::Wizard::BaseParseStepComponent
  private

  def save_html_path
    helpers.save_html_admin_songs_list_wizard_path(list_id: list.id)
  end

  def step_status_path
    helpers.step_status_admin_songs_list_wizard_path(list_id: list.id, step: "parse")
  end

  def advance_step_path
    helpers.advance_step_admin_songs_list_wizard_path(list_id: list.id, step: "parse")
  end

  def reparse_path
    helpers.reparse_admin_songs_list_wizard_path(list_id: list.id)
  end

  def step_path
    helpers.step_admin_songs_list_wizard_path(list_id: list.id, step: "parse")
  end

  def entity_name
    "song"
  end

  def entity_name_plural
    "songs"
  end
end
