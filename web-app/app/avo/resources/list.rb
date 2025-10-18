class Avo::Resources::List < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  self.model_class = ::List
  self.title = :name
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :type, as: :text, readonly: true
    field :name, as: :text
    field :description, as: :textarea
    field :source, as: :text
    field :url, as: :text
    field :status, as: :select, enum: ::List.statuses
    field :estimated_quality, as: :number
    field :high_quality_source, as: :boolean
    field :category_specific, as: :boolean
    field :location_specific, as: :boolean
    field :year_published, as: :number
    field :yearly_award, as: :boolean
    field :number_of_voters, as: :number
    field :voter_count_unknown, as: :boolean
    field :voter_names_unknown, as: :boolean
    field :num_years_covered, as: :number, help: "Number of years this list covers (e.g., 10 for 'Best Albums of the 2010s', 1 for 'Best Albums of 2020')"
    field :formatted_text, as: :textarea
    field :raw_html, as: :textarea, only_on: [:edit, :new]
    field :simplified_html, as: :textarea, only_on: [:edit, :new]
    field :submitted_by_id, as: :number
    field :list_items, as: :has_many
    field :submitted_by, as: :belongs_to
    field :list_penalties, as: :has_many
    field :penalties, as: :has_many, through: :list_penalties
    field :ai_chats, as: :has_many
    field :items_json, as: :code, only_on: [:show, :edit, :new], format: :json, pretty_generated: true, height: "800px"
  end

  def actions
    action Avo::Actions::Lists::ParseWithAi
  end
end
