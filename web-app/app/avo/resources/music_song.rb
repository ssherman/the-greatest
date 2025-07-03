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
    field :slug, as: :text
    field :description, as: :textarea
    field :duration_secs, as: :number
    field :release_year, as: :number
    field :isrc, as: :text
    field :lyrics, as: :textarea
    field :created_at, as: :date_time
    field :updated_at, as: :date_time
  end
end
