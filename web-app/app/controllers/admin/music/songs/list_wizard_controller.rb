# frozen_string_literal: true

# ListWizardController handles the multi-step wizard for importing songs into a list.
# Inherits shared functionality from Admin::Music::BaseListWizardController.
#
# @see Admin::Music::BaseListWizardController
#
class Admin::Music::Songs::ListWizardController < Admin::Music::BaseListWizardController
  private

  def list_class
    Music::Songs::List
  end

  def entity_id_key
    "song_id"
  end

  def enrichment_id_key
    "mb_recording_id"
  end

  # Configuration for job-based wizard steps
  def job_step_config
    @job_step_config ||= {
      "parse" => {
        job_class: "Music::Songs::WizardParseListJob",
        action_name: "Parsing",
        re_run_param: nil
      },
      "enrich" => {
        job_class: "Music::Songs::WizardEnrichListItemsJob",
        action_name: "Enrichment",
        re_run_param: :reenrich
      },
      "validate" => {
        job_class: "Music::Songs::WizardValidateListItemsJob",
        action_name: "Validation",
        re_run_param: :revalidate
      },
      "import" => {
        job_class: "Music::Songs::WizardImportSongsJob",
        action_name: "Import",
        re_run_param: nil,
        set_completed_on_advance: true
      }
    }.freeze
  end
end
