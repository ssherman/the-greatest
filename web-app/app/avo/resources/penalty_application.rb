class Avo::Resources::PenaltyApplication < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :penalty, as: :belongs_to
    field :ranking_configuration, as: :belongs_to
    field :value, as: :number
  end
end
