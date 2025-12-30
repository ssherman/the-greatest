# frozen_string_literal: true

# Album-specific wizard import job.
# Inherits shared import logic from BaseWizardImportJob.
#
# Supports two import paths:
# - custom_html: Imports albums one-by-one from parsed items with MB release group IDs
# - musicbrainz_series: Falls back to custom_html logic (series import not yet implemented)
#
class Music::Albums::WizardImportAlbumsJob < Music::BaseWizardImportJob
  private

  def list_class
    Music::Albums::List
  end

  def enrichment_id_key
    "mb_release_group_id"
  end

  def importer_class
    DataImporters::Music::Album::Importer
  end

  def importer_params(mb_id)
    {release_group_musicbrainz_id: mb_id}
  end

  def imported_id_key
    "imported_album_id"
  end

  # Series import for albums uses default behavior from base class
  # (falls back to custom_html logic since series import is not implemented)
end
