class Avo::Resources::MoviesMovie < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  self.model_class = ::Movies::Movie
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :title, as: :text
    field :slug, as: :text
    field :description, as: :textarea
    field :release_year, as: :number
    field :runtime_minutes, as: :number
    field :rating, as: :number
  end
end
