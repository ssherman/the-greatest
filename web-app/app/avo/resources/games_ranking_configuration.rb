class Avo::Resources::GamesRankingConfiguration < Avo::Resources::RankingConfiguration
  self.model_class = ::Games::RankingConfiguration

  def fields
    super

    # Override specific associations to use the correct resources
    field :inherited_from, as: :belongs_to, use_resource: Avo::Resources::GamesRankingConfiguration
    field :primary_mapped_list, as: :belongs_to, use_resource: Avo::Resources::GamesList
    field :secondary_mapped_list, as: :belongs_to, use_resource: Avo::Resources::GamesList
    field :inherited_configurations, as: :has_many, use_resource: Avo::Resources::GamesRankingConfiguration
  end
end
