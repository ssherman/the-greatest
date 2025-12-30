# frozen_string_literal: true

# ListWizardController handles the multi-step wizard for importing albums into a list.
# Inherits shared functionality from Admin::Music::BaseListWizardController.
#
# @see Admin::Music::BaseListWizardController
#
class Admin::Music::Albums::ListWizardController < Admin::Music::BaseListWizardController
  private

  def list_class
    Music::Albums::List
  end

  def entity_id_key
    "album_id"
  end

  def enrichment_id_key
    "mb_release_group_id"
  end

  # Configuration for job-based wizard steps
  def job_step_config
    @job_step_config ||= {
      "parse" => {
        job_class: "Music::Albums::WizardParseListJob",
        action_name: "Parsing",
        re_run_param: nil
      },
      "enrich" => {
        job_class: "Music::Albums::WizardEnrichListItemsJob",
        action_name: "Enrichment",
        re_run_param: :reenrich
      },
      "validate" => {
        job_class: "Music::Albums::WizardValidateListItemsJob",
        action_name: "Validation",
        re_run_param: :revalidate
      },
      "import" => {
        job_class: "Music::Albums::WizardImportAlbumsJob",
        action_name: "Import",
        re_run_param: nil,
        set_completed_on_advance: true
      }
    }.freeze
  end
end
