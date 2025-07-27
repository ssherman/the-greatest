class Avo::Resources::Identifier < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  # self.search = {
  #   query: -> { query.ransack(id_eq: q, m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :identifiable, as: :text
    field :identifier_type, as: :number
    field :value, as: :text
  end
end
