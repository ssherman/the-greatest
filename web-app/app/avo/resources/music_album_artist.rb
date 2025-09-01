class Avo::Resources::MusicAlbumArtist < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  self.model_class = ::Music::AlbumArtist
  # self.search = {
  #   query: -> { query.ransack(id_eq: q, m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :album, as: :belongs_to
    field :artist, as: :belongs_to
    field :position, as: :number
  end
end
