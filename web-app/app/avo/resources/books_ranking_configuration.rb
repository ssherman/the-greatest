class Avo::Resources::BooksRankingConfiguration < Avo::Resources::RankingConfiguration
  self.model_class = ::Books::RankingConfiguration

  def fields
    super

    # Override specific associations to use the correct resources
    field :inherited_from, as: :belongs_to, use_resource: Avo::Resources::BooksRankingConfiguration
    field :primary_mapped_list, as: :belongs_to, use_resource: Avo::Resources::BooksList
    field :secondary_mapped_list, as: :belongs_to, use_resource: Avo::Resources::BooksList
    field :inherited_configurations, as: :has_many, use_resource: Avo::Resources::BooksRankingConfiguration
  end
end
