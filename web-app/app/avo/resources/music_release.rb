class Avo::Resources::MusicRelease < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  self.model_class = ::Music::Release
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :album, as: :belongs_to
    field :release_name, as: :text
    field :format, as: :select, enum: ::Music::Release.formats
    field :country, as: :text
    field :status, as: :select, enum: ::Music::Release.statuses
    field :labels, as: :tags
    field :release_date, as: :date
    field :metadata, as: :code

    # Associations
    field :tracks, as: :has_many
    field :songs, as: :has_many, through: :tracks
    field :identifiers, as: :has_many
    field :credits, as: :has_many
    field :images, as: :has_many
    field :primary_image, as: :has_one, readonly: true
    field :external_links, as: :has_many

    # Additional info
    field :created_at, as: :date_time, readonly: true
    field :updated_at, as: :date_time, readonly: true
  end
end
