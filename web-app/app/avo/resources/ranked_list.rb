class Avo::Resources::RankedList < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :weight, as: :number
    field :list, as: :text
    field :ranking_configuration, as: :belongs_to
  end
end
