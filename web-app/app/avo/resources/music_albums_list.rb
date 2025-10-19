class Avo::Resources::MusicAlbumsList < Avo::Resources::List
  self.model_class = ::Music::Albums::List

  def fields
    super

    field :musicbrainz_series_id, as: :text, help: "MusicBrainz Series ID for importing albums from series", show_on: [:show, :edit, :new]

    tool Avo::ResourceTools::Lists::Music::Albums::ItemsJsonViewer
  end

  def actions
    super

    action Avo::Actions::Lists::ImportFromMusicbrainzSeries
    action Avo::Actions::Lists::Music::Albums::EnrichItemsJson
    action Avo::Actions::Lists::Music::Albums::ValidateItemsJson
  end
end
