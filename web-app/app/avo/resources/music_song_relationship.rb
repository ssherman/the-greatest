class Avo::Resources::MusicSongRelationship < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  self.model_class = ::Music::SongRelationship
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :song, as: :belongs_to
    field :related_song, as: :belongs_to
    field :relation_type, as: :number
    field :source_release, as: :belongs_to
  end
end
