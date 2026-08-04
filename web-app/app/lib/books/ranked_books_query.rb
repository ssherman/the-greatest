module Books
  # The single place the ranked-books relation is built. Callers only ever see a
  # paginatable RankedItem relation, so a later filtering increment can swap the
  # engine here (OpenSearch id-set, materialized view) without touching views.
  class RankedBooksQuery
    def self.call(ranking_configuration:, categories: [], countries: [], year_start: nil, year_end: nil)
      relation = RankedItem
        .where(ranking_configuration_id: ranking_configuration.id, item_type: "Books::Book")
        .where.not(rank: nil)

      Array(categories).each do |category|
        relation = relation.where(
          item_id: CategoryItem.where(category_id: category.id, item_type: "Books::Book").select(:item_id)
        )
      end

      country_list = Array(countries)
      if country_list.any?
        relation = relation.where(
          item_id: Books::BookCountry.where(country_id: country_list.map(&:id)).select(:book_id)
        )
      end

      relation = with_year_bounds(relation, year_start, year_end)

      relation
        .includes(item: [{book_authors: :author}, {primary_image: {file_attachment: :blob}}])
        .order(:rank)
    end

    def self.with_year_bounds(relation, year_start, year_end)
      return relation if year_start.blank? && year_end.blank?

      relation = relation.joins("INNER JOIN books_books ON books_books.id = ranked_items.item_id")
      relation = relation.where("books_books.first_published_year >= ?", year_start) if year_start.present?
      relation = relation.where("books_books.first_published_year <= ?", year_end) if year_end.present?
      relation
    end
    private_class_method :with_year_bounds
  end
end
