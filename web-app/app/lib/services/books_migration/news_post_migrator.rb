module Services
  module BooksMigration
    # Legacy blog_posts -> news_posts, domain :books. One-time lift.
    #
    # Dropped on purpose, each verified against the real corpus:
    #   front_page -- true on 27 of 31 and read by NO legacy code
    #   pinned     -- false on all 31
    #   tags       -- empty on all 31; news_topics replaces it
    #   Blog       -- one row, titled "Default", whose only job was to be a parent
    #
    # Topics are NOT assigned here. There is no legacy source for them, and
    # guessing from title keywords is not worth the code on a 31-row job that
    # gets reviewed by hand anyway.
    #
    # Idempotent by slug: re-running skips posts already present. Deliberately
    # NOT a re-sync -- it will not update a post whose body has been edited in
    # admin since the last run.
    #
    # Deliberately NOT a Migrator subclass, unlike its ~37 siblings. Migrator's
    # legacy_each yields record.attributes (a String-keyed hash) and upsert_row is
    # written against that; this migrator needs legacy.body_html, which reads the
    # has_one :rich_text_content association on a separate table and is not an
    # attribute. Inheriting would mean overriding legacy_each to yield records and
    # breaking the base's contract. The one thing worth borrowing -- a per-row
    # rescue naming the legacy id -- is reproduced below.
    class NewsPostMigrator
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      def self.call = new.call

      def call
        created = 0
        skipped = 0
        round_trip_failures = []

        ::LegacyBooks::BlogPost.order(:id).each do |legacy|
          if ::NewsPost.books.exists?(slug: legacy.slug)
            skipped += 1
            next
          end

          html = legacy.body_html
          round_trip_failures << legacy.id unless NewsBodyConverter.round_trips?(html)

          ::NewsPost.create!(
            domain: :books,
            title: legacy.title,
            # Assigned directly so friendly_id leaves it alone. The legacy slug
            # is a live public URL -- including the one UUID-suffixed collision
            # slug -- and regenerating it from the title would break it.
            slug: legacy.slug,
            body: NewsBodyConverter.call(html),
            published_at: legacy.created_at,
            created_at: legacy.created_at,
            updated_at: legacy.updated_at,
            user_id: legacy.user_id
          )
          created += 1
        rescue => e
          # Mirrors Migrator's per-row rescue: a failure names the legacy row that
          # caused it and how far the run got, rather than surfacing a bare
          # ActiveRecord error with no context. Re-raised, not swallowed -- the run
          # is idempotent by slug, so re-running after a fix skips what already
          # landed.
          raise "NewsPost migration failed at legacy id=#{legacy.id} (#{created} created, #{skipped} skipped): #{e.message}"
        end

        Result.new(
          success?: true,
          data: {created:, skipped:, round_trip_failures:},
          errors: []
        )
      end
    end
  end
end
