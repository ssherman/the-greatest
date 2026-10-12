module Books
  # Resolves a category slug a visitor (or an old inbound link) used to the
  # category they should land on: an active category, a category merged away
  # (-> its target), or a slug the category had before a rename (friendly_id
  # history). Returns nil when nothing live answers to the slug.
  class CategorySlugResolver
    # Must match friendly_id's serialized scope for `scope: :type` on Category.
    HISTORY_SCOPE = "type:Books::Category"

    def self.call(slug)
      new(slug).call
    end

    def initialize(slug)
      @slug = slug.to_s
    end

    def call
      active = Books::Category.active.find_by(slug: @slug)
      return active if active

      merged = Books::Category.merged.find_by(slug: @slug)
      return merged.canonical if merged

      historical = FriendlyId::Slug
        .where(sluggable_type: "Category", scope: HISTORY_SCOPE, slug: @slug)
        .order(id: :desc).first
      return nil if historical.nil?

      Books::Category.find_by(id: historical.sluggable_id)&.canonical
    end
  end
end
