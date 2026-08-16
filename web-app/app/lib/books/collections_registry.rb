module Books
  # The six curated collections migrated from the legacy site's Lists nav menu.
  # NOT named Books::Collections -- that would shadow the shared ::Collections
  # module for every constant lookup inside this namespace.
  #
  # `filter` shapes are read only by Books::RankedBooksQuery.
  class CollectionsRegistry
    def self.all
      @all ||= [
        build("women", "Greatest Books Written by Women",
          title_suffix: "Written by Women", filter: {author_gender: :female}),
        build("africa", "Greatest African Books",
          title_prefix: "African", filter: {country_label: "african"}),
        build("asia", "Greatest Asian Books",
          title_prefix: "Asian", filter: {country_label: "asian"}),
        build("latin-america", "Greatest Latin American Books",
          title_prefix: "Latin American", filter: {country_label: "latin_american"}),
        build("western", "Greatest Western Canon Books",
          title_prefix: "Western", filter: {country_label: "western"}),
        build("non-western", "Greatest Non-Western Canon Books",
          title_prefix: "Non-Western", filter: {country_label: "western", exclude: true})
      ].freeze
    end

    def self.build(slug, name, filter:, title_prefix: nil, title_suffix: nil)
      ::Collections::Collection.new(
        domain: :books, slug: slug, name: name,
        title_prefix: title_prefix, title_suffix: title_suffix, filter: filter
      )
    end
    private_class_method :build
  end
end
