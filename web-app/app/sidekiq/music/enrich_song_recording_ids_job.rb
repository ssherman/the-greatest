# frozen_string_literal: true

class Music::EnrichSongRecordingIdsJob
  include Sidekiq::Job

  sidekiq_options queue: :serial

  def perform(song_id)
    song = Music::Song.find(song_id)

    # Call enrichment service (handles both MBID and name-based search)
    result = Services::Music::Songs::RecordingIdEnricher.call(song: song)

    if result.success?
      data = result.data

      if data[:skip_reason]
        Rails.logger.info "EnrichSongRecordingIds: Song #{song.id} skipped: #{data[:skip_reason]}"
      elsif data[:new_identifiers_created] > 0 || data[:existing_identifiers] > 0
        Rails.logger.info "EnrichSongRecordingIds: Song #{song.id} enriched (#{data[:new_identifiers_created]} new, #{data[:existing_identifiers]} existing recording IDs)"

        # Update release year from all identifiers (handles retry scenarios)
        updated = song.update_release_year_from_identifiers!
        Rails.logger.info "EnrichSongRecordingIds: Song #{song.id} release_year #{updated ? "updated" : "unchanged"}"
      else
        Rails.logger.info "EnrichSongRecordingIds: Song #{song.id} - no recording IDs found"
      end
    else
      error_msg = result.errors.join(", ")
      Rails.logger.error "EnrichSongRecordingIds: Song #{song.id} enrichment failed: #{error_msg}"
      raise StandardError, "Recording ID enrichment failed: #{error_msg}"
    end
  end
end
