class Avo::Resources::MusicSong < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  self.model_class = ::Music::Song
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :title, as: :text
    field :slug, as: :text, readonly: true
    field :description, as: :textarea
    field :notes, as: :textarea
    field :duration_secs, as: :number
    field :release_year, as: :number
    field :isrc, as: :text
    field :lyrics, as: :textarea

    # Associations
    field :artists, as: :has_many
    field :categories, as: :has_many
    field :identifiers, as: :has_many
    field :credits, as: :has_many
    field :tracks, as: :has_many
    field :external_links, as: :has_many

    field :created_at, as: :date_time, readonly: true
    field :updated_at, as: :date_time, readonly: true
  end
end
