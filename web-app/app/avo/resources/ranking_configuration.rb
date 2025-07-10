class Avo::Resources::RankingConfiguration < Avo::BaseResource
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
    field :primary, as: :boolean
    field :archived, as: :boolean
    field :published_at, as: :date_time
    field :algorithm_version, as: :number
    field :exponent, as: :number
    field :bonus_pool_percentage, as: :number
    field :min_list_weight, as: :number
    field :list_limit, as: :number
    field :apply_list_dates_penalty, as: :boolean
    field :max_list_dates_penalty_age, as: :number
    field :max_list_dates_penalty_percentage, as: :number
    field :inherit_penalties, as: :boolean
    field :inherited_from, as: :belongs_to
    field :user, as: :belongs_to
    field :primary_mapped_list, as: :belongs_to
    field :secondary_mapped_list, as: :belongs_to
    field :primary_mapped_list_cutoff_limit, as: :number
  end
end
