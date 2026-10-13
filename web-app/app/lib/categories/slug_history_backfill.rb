# friendly_id's :history module only knows slugs recorded in friendly_id_slugs.
# Categories predate it, so without a row per existing category a rename loses the
# old slug, and the slug-conflict check (an INNER JOIN on that table) can't see the
# category, letting a new one reuse its slug. This inserts the missing rows.
#
# Idempotent (ON CONFLICT on the unique slug/type/scope index) and never writes to
# categories. The scope string is friendly_id's serialization of `scope: :type`.
module Categories
  class SlugHistoryBackfill
    SQL = <<~SQL.squish.freeze
      INSERT INTO friendly_id_slugs (slug, sluggable_id, sluggable_type, scope, created_at)
      SELECT slug, id, 'Category', 'type:' || type, NOW()
      FROM categories
      WHERE slug IS NOT NULL
      ON CONFLICT DO NOTHING
    SQL

    # Returns the number of rows inserted.
    def self.call
      ::Category.connection.exec_update(SQL)
    end
  end
end
