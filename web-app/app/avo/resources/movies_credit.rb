class Avo::Resources::MoviesCredit < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  self.model_class = ::Movies::Credit
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :person, as: :belongs_to
    field :creditable, as: :text
    field :role, as: :number
    field :position, as: :number
    field :character_name, as: :text
  end
end
