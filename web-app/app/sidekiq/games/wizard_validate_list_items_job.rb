# frozen_string_literal: true

# Games-specific wizard validate job.
# Inherits shared validation logic from BaseWizardValidateListItemsJob.
#
class Games::WizardValidateListItemsJob < ::BaseWizardValidateListItemsJob
  private

  def list_class
    Games::List
  end

  def validator_task_class
    Services::Ai::Tasks::Lists::Games::ListItemsValidatorTask
  end

  def entity_id_key
    "game_id"
  end

  def enrichment_id_key
    "igdb_id"
  end
end
