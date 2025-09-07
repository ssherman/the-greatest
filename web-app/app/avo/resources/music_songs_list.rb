class Avo::Resources::MusicSongsList < Avo::Resources::List
  self.model_class = ::Music::Songs::List

  def fields
    super

    field :musicbrainz_series_id, as: :text, help: "MusicBrainz Series ID (albums only for now)", readonly: true
  end
end
