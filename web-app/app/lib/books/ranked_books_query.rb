module Books
  # The single place the ranked-books relation is built. Callers only ever see a
  # paginatable RankedItem relation, so a later filtering increment can swap the
  # engine here (OpenSearch id-set, materialized view) without touching views.
  class RankedBooksQuery
    def self.call(ranking_configuration:)
      RankedItem
        .where(ranking_configuration_id: ranking_configuration.id, item_type: "Books::Book")
        .includes(item: [{book_authors: :author}, {primary_image: {file_attachment: :blob}}])
        .order(:rank)
    end
  end
end
