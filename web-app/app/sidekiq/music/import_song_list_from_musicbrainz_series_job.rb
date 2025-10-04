class Music::ImportSongListFromMusicbrainzSeriesJob
  include Sidekiq::Job

  def perform(list_id)
    list = ::Music::Songs::List.find(list_id)
    DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries.call(list: list)
  rescue ActiveRecord::RecordNotFound => e
    Rails.logger.error "ImportSongListFromMusicbrainzSeriesJob: List not found - #{e.message}"
    raise
  rescue => e
    Rails.logger.error "ImportSongListFromMusicbrainzSeriesJob failed: #{e.message}"
    raise
  end
end
