class Avo::Resources::MusicAlbumsRankingConfiguration < Avo::BaseResource
  # self.includes = []
  # self.attachments = []
  self.model_class = "Music::Albums::RankingConfiguration"
  self.title = :name
  # self.search = {
  #   query: -> { query.ransack(id_eq: params[:q], m: "or").result(distinct: false) }
  # }

  def fields
    field :id, as: :id
    field :type, as: :text, readonly: true
    field :name, as: :text
    field :description, as: :textarea
    field :global, as: :boolean
    field :primary, as: :boolean
    field :archived, as: :boolean
    field :published_at, as: :datetime, readonly: true
    field :algorithm_version, as: :number
    field :exponent, as: :number
    field :bonus_pool_percentage, as: :number
    field :min_list_weight, as: :number
    field :list_limit, as: :number, nullable: true
    field :apply_list_dates_penalty, as: :boolean
    field :max_list_dates_penalty_age, as: :number
    field :max_list_dates_penalty_percentage, as: :number
    field :inherit_penalties, as: :boolean
    field :primary_mapped_list_cutoff_limit, as: :number, nullable: true
    field :inherited_from, as: :belongs_to, use_resource: Avo::Resources::MusicAlbumsRankingConfiguration
    field :user, as: :belongs_to, readonly: true
    field :primary_mapped_list, as: :belongs_to, use_resource: Avo::Resources::MusicAlbumsList
    field :secondary_mapped_list, as: :belongs_to, use_resource: Avo::Resources::MusicAlbumsList
    field :ranked_items, as: :has_many
    field :ranked_lists, as: :has_many
    field :penalty_applications, as: :has_many
    # field :inherited_configurations, as: :has_many, use_resource: Avo::Resources::MusicAlbumsRankingConfiguration
  end
end
