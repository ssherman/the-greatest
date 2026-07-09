module Services
  module BooksMigration
    # Legacy `links` -> polymorphic ExternalLink, parented to Books::Book (preserved
    # ids), submitted_by -> the migrated user. Per-row AR (find_or_initialize_by on the
    # natural key [parent, url]) because external_links has no unique index to upsert
    # against. Validations run, so fail-loud is free: a missing Books::Book fails the
    # required belongs_to :parent, a missing user hits the submitted_by_id DB FK; the
    # base rescue names the legacy link id. `source` is inferred from the URL host by
    # string ops (not URI.parse, which raises on the non-ASCII Wikipedia urls). `name`
    # is migrated verbatim, `link_category` is always :information, and scheme-less urls
    # are normalized to https://. Legacy created_at/updated_at are preserved (assigning
    # non-nil timestamps leaves AR's create-time callback untouched). Idempotent on
    # [parent, url].
    class ExternalLinkMigrator < Migrator
      private

      def legacy_model
        LegacyBooks::Link
      end

      def model_key
        "ExternalLink"
      end

      def upsert_row(attrs)
        url = normalize_url(attrs["url"])
        source = source_for(url)
        link = ExternalLink.find_or_initialize_by(
          parent_type: "Books::Book",
          parent_id: attrs["book_id"],
          url: url
        )
        link.assign_attributes(
          name: attrs["name"],
          description: attrs["description"],
          submitted_by_id: attrs["user_id"],
          source: source,
          source_name: ((source == :other) ? extract_host(url) : nil),
          link_category: :information,
          public: true,
          created_at: attrs["created_at"],
          updated_at: attrs["updated_at"]
        )
        link.save!
      end

      def normalize_url(url)
        url.to_s.match?(%r{\Ahttps?://}i) ? url : "https://#{url}"
      end

      def extract_host(url)
        url.to_s.sub(%r{\Ahttps?://}i, "").split("/").first.to_s.downcase.sub(/\Awww\./, "")
      end

      def source_for(url)
        host = extract_host(url)
        return :wikipedia if host.end_with?("wikipedia.org")
        return :goodreads if host == "goodreads.com" || host.end_with?(".goodreads.com")
        return :amazon if host.include?("amazon.")
        return :bookshop_org if host == "bookshop.org" || host.end_with?(".bookshop.org")
        :other
      end
    end
  end
end
