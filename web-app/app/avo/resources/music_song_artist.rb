class Avo::Resources::MusicSongArtist < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  self.model_class = ::Music::SongArtist
  # self.search = {
  #   query: -> { query.ransack(id_eq: q, m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :song, as: :belongs_to
    field :artist, as: :belongs_to
    field :position, as: :number
  end
end
