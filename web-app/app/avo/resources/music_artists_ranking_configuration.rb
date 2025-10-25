class Avo::Resources::MusicArtistsRankingConfiguration < Avo::Resources::RankingConfiguration
  self.model_class = ::Music::Artists::RankingConfiguration

  def fields
    super

    # Override specific associations to use the correct resources
    field :inherited_from, as: :belongs_to, use_resource: Avo::Resources::MusicArtistsRankingConfiguration
    # Note: Artists don't use mapped lists - they aggregate from album/song rankings
    # field :inherited_configurations, as: :has_many, use_resource: Avo::Resources::MusicArtistsRankingConfiguration
  end
end
