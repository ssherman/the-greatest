module Books
  # The single place the ranked-books relation is built. Callers only ever see a
  # paginatable RankedItem relation, so a later filtering increment can swap the
  # engine here (OpenSearch id-set, materialized view) without touching views.
  class RankedBooksQuery
    def self.call(ranking_configuration:, categories: [], countries: [], year_start: nil, year_end: nil, collection: nil)
      relation = ranked_books(ranking_configuration)

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

      relation = with_collection(relation, collection)
      relation = with_year_bounds(relation, year_start, year_end)

      relation
        .includes(item: [{book_authors: :author}, {primary_image: {file_attachment: :blob}}])
        .order(:rank)
    end

    # {category_id => ranked books carrying it} for many categories in one
    # query: the same count `call(categories: [category])` gives one at a time.
    # A category with none has no key.
    def self.counts_by_category(ranking_configuration:, category_ids:)
      ranked_books(ranking_configuration)
        .joins("INNER JOIN category_items ON category_items.item_id = ranked_items.item_id AND category_items.item_type = 'Books::Book'")
        .where(category_items: {category_id: category_ids})
        .group("category_items.category_id")
        .count
    end

    # {country_id => distinct ranked books of that country}: the same count
    # `call(countries: [country])` gives. Counts are per country group, and
    # (book, country) is unique, so DISTINCT is only a safeguard.
    def self.counts_by_country(ranking_configuration:)
      ranked_books(ranking_configuration)
        .joins("INNER JOIN books_book_countries ON books_book_countries.book_id = ranked_items.item_id")
        .group("books_book_countries.country_id")
        .count("DISTINCT ranked_items.item_id")
    end

    # {[category_id, country_id] => distinct ranked books carrying both}: the same
    # count `call(categories: [category], countries: [country])` gives.
    def self.counts_by_category_and_country(ranking_configuration:, category_ids:)
      ranked_books(ranking_configuration)
        .joins("INNER JOIN category_items ON category_items.item_id = ranked_items.item_id AND category_items.item_type = 'Books::Book'")
        .joins("INNER JOIN books_book_countries ON books_book_countries.book_id = ranked_items.item_id")
        .where(category_items: {category_id: category_ids})
        .group("category_items.category_id", "books_book_countries.country_id")
        .count("DISTINCT ranked_items.item_id")
    end

    def self.ranked_books(ranking_configuration)
      RankedItem
        .where(ranking_configuration_id: ranking_configuration.id, item_type: "Books::Book")
        .where.not(rank: nil)
    end
    private_class_method :ranked_books

    # A collection's `filter` is opaque to the shared registry -- this is the only
    # place in the app that knows what its keys mean.
    def self.with_collection(relation, collection)
      filter = collection&.filter
      return relation if filter.nil?

      if filter[:author_gender]
        relation.where(item_id: Books::BookAuthor
          .where(author_id: Books::Author.where(gender: filter[:author_gender]).select(:id))
          .select(:book_id))
      else
        countries = if filter[:exclude]
          Books::Country.without_label(filter[:country_label])
        else
          Books::Country.with_label(filter[:country_label])
        end
        relation.where(item_id: Books::BookCountry.where(country_id: countries.select(:id)).select(:book_id))
      end
    end
    private_class_method :with_collection

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
