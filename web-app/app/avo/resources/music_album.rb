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
    field :slug, as: :text
    field :description, as: :textarea
    field :primary_artist, as: :belongs_to
    field :release_year, as: :number
    field :created_at, as: :date_time
    field :updated_at, as: :date_time
  end
end
