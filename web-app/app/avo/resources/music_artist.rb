class Avo::Resources::MusicArtist < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  self.model_class = ::Music::Artist
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :name, as: :text
    field :slug, as: :text, readonly: true
    field :description, as: :textarea
    field :kind, as: :select, enum: ::Music::Artist.kinds
    field :country, as: :country
    field :born_on, as: :date
    field :died_on, as: :date
    field :formed_on, as: :date
    field :disbanded_on, as: :date
  end
end
