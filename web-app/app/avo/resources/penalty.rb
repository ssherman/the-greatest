class Avo::Resources::Penalty < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :type, as: :text
    field :name, as: :text
    field :description, as: :textarea
    field :global, as: :boolean
    field :user, as: :belongs_to
    field :media_type, as: :select, options: ::Penalty.media_types
    field :dynamic, as: :boolean
  end
end
