module Collections
  # Looks up a domain's collections. Providers are resolved by convention --
  # `Books::CollectionsRegistry` -- so registering a domain is one new file and
  # no edit here. Root-anchored constant lookup (`::Books`) is deliberate: a
  # bare `Books::` inside `Collections::` would resolve to a nested module.
  class Registry
    PROVIDERS = {books: "::Books::CollectionsRegistry"}.freeze

    def self.for(domain)
      provider = PROVIDERS[domain.to_sym]
      return [] if provider.nil?

      provider.constantize.all
    end

    def self.find(domain, slug)
      self.for(domain).find { |collection| collection.slug == slug.to_s }
    end

    def self.slugs(domain)
      self.for(domain).map(&:slug)
    end
  end
end
