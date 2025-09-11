class Avo::Resources::MusicAlbum < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  self.model_class = ::Music::Album
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :title, as: :text
    field :slug, as: :text, readonly: true
    field :description, as: :textarea
    field :artists, as: :has_many
    field :release_year, as: :number

    # Associations
    field :releases, as: :has_many
    field :categories, as: :has_many
    field :identifiers, as: :has_many
    field :credits, as: :has_many
    field :images, as: :has_many
    field :primary_image, as: :has_one, readonly: true

    # Additional info
    field :created_at, as: :date_time, readonly: true
    field :updated_at, as: :date_time, readonly: true
  end
end
