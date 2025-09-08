class Avo::Resources::MusicSongsRankingConfiguration < Avo::Resources::RankingConfiguration
  self.model_class = ::Music::Songs::RankingConfiguration

  def fields
    super

    # Override specific associations to use the correct resources
    field :inherited_from, as: :belongs_to, use_resource: Avo::Resources::MusicSongsRankingConfiguration
    field :primary_mapped_list, as: :belongs_to, use_resource: Avo::Resources::MusicSongsList
    field :secondary_mapped_list, as: :belongs_to, use_resource: Avo::Resources::MusicSongsList
    field :inherited_configurations, as: :has_many, use_resource: Avo::Resources::MusicSongsRankingConfiguration
  end
end
