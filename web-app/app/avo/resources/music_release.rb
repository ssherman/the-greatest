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
    field :format, as: :badge, options: Music::Release.formats
    field :country, as: :text
    field :status, as: :badge, options: Music::Release.statuses
    field :labels, as: :tags
    field :release_date, as: :date
    field :metadata, as: :code
    field :created_at, as: :date_time, readonly: true
    field :updated_at, as: :date_time, readonly: true
  end
end
