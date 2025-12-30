# frozen_string_literal: true

# Album-specific wizard validate job.
# Inherits shared validation logic from BaseWizardValidateListItemsJob.
#
class Music::Albums::WizardValidateListItemsJob < Music::BaseWizardValidateListItemsJob
  private

  def list_class
    Music::Albums::List
  end

  def validator_task_class
    Services::Ai::Tasks::Lists::Music::Albums::ListItemsValidatorTask
  end

  def entity_id_key
    "album_id"
  end

  def enrichment_id_key
    "mb_release_group_id"
  end
end
