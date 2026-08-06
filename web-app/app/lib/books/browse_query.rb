module Books
  class BrowseQuery
    TYPES = %w[genre location subject].freeze
    SORTS = %w[book_count name].freeze

    def self.categories(type: nil, sort: nil)
      scope = Books::Category.active
        .where(category_type: normalized_type(type))
        .where("item_count > 0")

      (normalized_sort(sort) == "name") ? scope.order(name: :asc) : scope.order(item_count: :desc, name: :asc)
    end

    def self.countries(sort: nil)
      scope = Books::Country.filterable.where("book_count > 0")

      (normalized_sort(sort) == "name") ? scope.order(name: :asc) : scope.order(book_count: :desc, name: :asc)
    end

    def self.normalized_type(type)
      TYPES.include?(type.to_s) ? type.to_s : TYPES.first
    end

    def self.normalized_sort(sort)
      SORTS.include?(sort.to_s) ? sort.to_s : SORTS.first
    end
  end
end
