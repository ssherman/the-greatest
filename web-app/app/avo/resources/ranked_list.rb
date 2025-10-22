class Avo::Resources::RankedList < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :weight, as: :number

    field :calculated_weight_details,
      as: :code,
      format_using: -> {
        if value.present?
          JSON.pretty_generate(value)
        else
          "No calculation details available"
        end
      },
      only_on: :show,
      help: "Complete breakdown of weight calculation including all penalties, formulas, and intermediate values"

    field :list, as: :belongs_to
    field :ranking_configuration, as: :belongs_to
  end
end
