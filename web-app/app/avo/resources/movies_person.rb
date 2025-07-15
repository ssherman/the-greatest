class Avo::Resources::MoviesPerson < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  self.model_class = ::Movies::Person
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :name, as: :text
    field :slug, as: :text, readonly: true
    field :description, as: :textarea
    field :born_on, as: :date
    field :died_on, as: :date
    field :country, as: :country
    field :gender, as: :number
  end
end
