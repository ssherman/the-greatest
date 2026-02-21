# frozen_string_literal: true

# Games-specific wizard import job.
# Inherits shared import logic from BaseWizardImportJob.
#
# Only supports custom_html import source (no series import for games).
#
class Games::WizardImportGamesJob < ::BaseWizardImportJob
  private

  def list_class
    Games::List
  end

  def enrichment_id_key
    "igdb_id"
  end

  def importer_class
    DataImporters::Games::Game::Importer
  end

  def importer_params(igdb_id)
    {igdb_id: igdb_id}
  end

  def imported_id_key
    "imported_game_id"
  end
end
