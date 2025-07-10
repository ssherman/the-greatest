class Avo::Resources::RankedItem < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :rank, as: :number
    field :score, as: :number
    field :item, as: :text
    field :ranking_configuration, as: :belongs_to
  end
end
