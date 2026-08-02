module Books
  # The single place the ranked-authors relation is built, so a later filtering
  # increment can swap the engine here without touching views.
  class RankedAuthorsQuery
    def self.call(ranking_configuration:)
      RankedItem
        .where(ranking_configuration_id: ranking_configuration.id, item_type: "Books::Author")
        .where.not(rank: nil)
        .includes(item: :descriptions)
        .order(:rank)
    end
  end
end
