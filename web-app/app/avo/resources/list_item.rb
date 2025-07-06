class Avo::Resources::ListItem < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :list, as: :belongs_to
    field :listable, as: :text
    field :position, as: :number
  end
end
