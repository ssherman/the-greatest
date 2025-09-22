class Avo::Resources::RankedItem < Avo::BaseResource
  self.title = -> { "##{record.rank} - #{record.item&.title || record.item&.name || record.item_type}" }
  self.description = "Ranked items with their scores and positions in ranking configurations"

  # Sort by rank (1 first, 2 second, etc.)
  self.default_sort_column = :rank
  self.default_sort_direction = :asc

  def fields
    field :id, as: :id
    field :rank, as: :number, sortable: true
    field :score, as: :number, format_using: -> { record.score&.round(3) }

    # Polymorphic association linking to the appropriate resource
    field :item, as: :belongs_to, polymorphic_as: :item, types: [
      ::Music::Album,
      ::Music::Song,
      ::Movies::Movie
    ]

    field :ranking_configuration, as: :belongs_to
    field :created_at, as: :date_time, readonly: true
    field :updated_at, as: :date_time, readonly: true
  end
end
