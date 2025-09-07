class ImportListFromMusicbrainzSeriesJob
  include Sidekiq::Job

  def perform(list_id)
    list = Music::Albums::List.find(list_id)
    DataImporters::Music::Lists::ImportFromMusicbrainzSeries.call(list: list)
  end
end
