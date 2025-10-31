class Avo::Resources::MusicSongsList < Avo::Resources::List
  self.model_class = ::Music::Songs::List

  def fields
    super

    field :musicbrainz_series_id, as: :text, help: "MusicBrainz Series ID for importing songs from series", show_on: [:show, :edit, :new]

    tool Avo::ResourceTools::Lists::Music::Songs::ItemsJsonViewer
  end

  def actions
    super

    action Avo::Actions::Lists::ImportFromMusicbrainzSeries
    action Avo::Actions::Lists::Music::Songs::EnrichItemsJson
    action Avo::Actions::Lists::Music::Songs::ValidateItemsJson
  end
end
