class Avo::Resources::MoviesRankingConfiguration < Avo::Resources::RankingConfiguration
  self.model_class = ::Movies::RankingConfiguration

  def fields
    super

    # Override specific associations to use the correct resources
    field :inherited_from, as: :belongs_to, use_resource: Avo::Resources::MoviesRankingConfiguration
    field :primary_mapped_list, as: :belongs_to, use_resource: Avo::Resources::MoviesList
    field :secondary_mapped_list, as: :belongs_to, use_resource: Avo::Resources::MoviesList
    field :inherited_configurations, as: :has_many, use_resource: Avo::Resources::MoviesRankingConfiguration
  end
end
