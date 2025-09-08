class Avo::Resources::MusicAlbumsRankingConfiguration < Avo::Resources::RankingConfiguration
  self.model_class = ::Music::Albums::RankingConfiguration

  def fields
    super

    # Override specific associations to use the correct resources
    field :inherited_from, as: :belongs_to, use_resource: Avo::Resources::MusicAlbumsRankingConfiguration
    field :primary_mapped_list, as: :belongs_to, use_resource: Avo::Resources::MusicAlbumsList
    field :secondary_mapped_list, as: :belongs_to, use_resource: Avo::Resources::MusicAlbumsList
    # field :inherited_configurations, as: :has_many, use_resource: Avo::Resources::MusicAlbumsRankingConfiguration
  end
end
