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
    field :born_on, as: :date
    field :year_died, as: :number
    field :year_formed, as: :number
    field :year_disbanded, as: :number
    field :country, as: :country

    # Associations
    field :albums, as: :has_many
    field :categories, as: :has_many
    field :identifiers, as: :has_many
    field :credits, as: :has_many

    # Additional info
    field :created_at, as: :date_time, readonly: true
    field :updated_at, as: :date_time, readonly: true
  end
end
