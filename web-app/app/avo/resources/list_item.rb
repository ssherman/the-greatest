class Avo::Resources::ListItem < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  # Sort by position by default (1 first, then 2, etc.)
  self.default_sort_column = :position
  self.default_sort_direction = :asc

  def fields
    field :id, as: :id
    field :list, as: :belongs_to
    field :listable, as: :text do
      if record.listable.respond_to?(:title)
        record.listable.title
      elsif record.listable.respond_to?(:name)
        record.listable.name
      else
        "#{record.listable.class.name} ##{record.listable.id}"
      end
    end
    field :position, as: :number
    field :verified, as: :boolean
    field :metadata, as: :code, language: :json
    field :created_at, as: :date_time, only_on: [:show]
    field :updated_at, as: :date_time, only_on: [:show]
  end
end
