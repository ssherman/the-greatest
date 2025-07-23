class Avo::Resources::MusicTrack < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  self.model_class = ::Music::Track
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :release, as: :belongs_to
    field :song, as: :belongs_to
    field :medium_number, as: :number
    field :position, as: :number
    field :length_secs, as: :number
    field :notes, as: :textarea
    field :created_at, as: :date_time, readonly: true
    field :updated_at, as: :date_time, readonly: true
  end
end
