# frozen_string_literal: true

# Song-specific wizard validate job.
# Inherits shared validation logic from BaseWizardValidateListItemsJob.
#
class Music::Songs::WizardValidateListItemsJob < Music::BaseWizardValidateListItemsJob
  private

  def list_class
    Music::Songs::List
  end

  def validator_task_class
    Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask
  end

  def entity_id_key
    "song_id"
  end

  def enrichment_id_key
    "mb_recording_id"
  end
end
