class Avo::Resources::MoviesRelease < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  self.model_class = ::Movies::Release
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :movie, as: :belongs_to
    field :release_name, as: :text
    field :release_format, as: :number
    field :runtime_minutes, as: :number
    field :release_date, as: :date
    field :metadata, as: :code
    field :is_primary, as: :boolean
  end
end
