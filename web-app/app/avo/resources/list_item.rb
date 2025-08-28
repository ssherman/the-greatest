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
    field :verified, as: :boolean
    field :metadata, as: :code, language: :json
    field :created_at, as: :date_time, only_on: [:show]
    field :updated_at, as: :date_time, only_on: [:show]
  end
end
