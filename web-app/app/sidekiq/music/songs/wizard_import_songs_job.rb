# frozen_string_literal: true

# Song-specific wizard import job.
# Inherits shared import logic from BaseWizardImportJob.
#
# Supports two import paths:
# - custom_html: Imports songs one-by-one from parsed items with MB recording IDs
# - musicbrainz_series: Uses series importer to bulk import songs
#
class Music::Songs::WizardImportSongsJob < Music::BaseWizardImportJob
  private

  def list_class
    Music::Songs::List
  end

  def enrichment_id_key
    "mb_recording_id"
  end

  def importer_class
    DataImporters::Music::Song::Importer
  end

  def importer_params(mb_id)
    {musicbrainz_recording_id: mb_id}
  end

  def imported_id_key
    "imported_song_id"
  end

  # Override series import with full series import logic
  def import_from_series
    @list.wizard_manager.update_step_status!(step: "import", status: "running", progress: 0, metadata: {
      "import_source" => "musicbrainz_series"
    })

    result = DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries.call(list: @list)

    if result[:success]
      verified_count = mark_series_items_as_verified

      @list.wizard_manager.update_step_status!(
        step: "import",
        status: "completed",
        progress: 100,
        metadata: {
          "import_source" => "musicbrainz_series",
          "imported_count" => result[:imported_count],
          "total_count" => result[:total_count],
          "failed_count" => result[:total_count] - result[:imported_count],
          "list_items_created" => result[:imported_count],
          "verified_count" => verified_count,
          "imported_at" => Time.current.iso8601
        }
      )

      Rails.logger.info "#{self.class.name} (series) completed for list #{@list.id}: " \
        "#{result[:imported_count]} of #{result[:total_count]} imported, #{verified_count} verified"
    else
      handle_error(result[:message] || "Series import failed")
    end
  end

  def mark_series_items_as_verified
    @list.list_items.where(verified: false).where.not(listable_id: nil).update_all(verified: true)
  end
end
