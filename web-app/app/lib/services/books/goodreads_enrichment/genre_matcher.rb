module Services
  module Books
    module GoodreadsEnrichment
      # Maps a Goodreads genre name onto a category we already hold. It only ever reads:
      # a name with no match returns nil and the caller skips it, because the category
      # tree is curated and a scraped genre list must not grow it.
      class GenreMatcher
        # Location is left out on purpose: Goodreads genres are never places, and a
        # shared word ("Paris") must not tag a book with a setting.
        TYPE_ORDER = %w[genre subject audience].freeze

        # Precedence across passes: exact name, then alternative name, then twin key.
        # Within a pass an active row beats a merged one; within that, TYPE_ORDER wins.
        PASSES = %i[name alternative_name twin_key].freeze

        def match(name)
          return nil if name.blank?

          PASSES.each do |pass|
            [active_index(pass), merged_index(pass)].each do |index|
              found = lookup(index, pass, name)
              return found if found
            end
          end
          nil
        end

        private

        # One query per instance, merge targets included, so a run over a whole genre
        # list costs the same as a run over one name.
        def rows
          @rows ||= ::Books::Category
            .where(category_type: TYPE_ORDER)
            .where("deleted = FALSE OR merged_into_id IS NOT NULL")
            .includes(:merged_into)
            .to_a
            .sort_by { |row| TYPE_ORDER.index(row.category_type) }
        end

        # A deleted row with no merge target is junk and never matches.
        def active_rows
          @active_rows ||= rows.reject(&:deleted?)
        end

        def merged_rows
          @merged_rows ||= rows.select { |row| row.deleted? && row.merged_into_id }
        end

        def active_index(pass)
          (@active_indexes ||= {})[pass] ||= build_index(active_rows, pass)
        end

        def merged_index(pass)
          (@merged_indexes ||= {})[pass] ||= build_index(merged_rows, pass)
        end

        # key -> rows in type order (rows is already sorted, and group_by keeps order).
        def build_index(source, pass)
          source.flat_map { |row| keys_for(row, pass).map { |key| [key, row] } }
            .group_by(&:first)
            .transform_values { |pairs| pairs.map(&:last) }
        end

        def keys_for(row, pass)
          case pass
          when :name then [row.name.downcase]
          when :alternative_name then Array(row.alternative_names).map(&:downcase)
          when :twin_key then [Services::CategoryCleanup::NameNormalizer.twin_key(row.name)].compact
          end
        end

        def query_key(pass, name)
          (pass == :twin_key) ? Services::CategoryCleanup::NameNormalizer.twin_key(name) : name.downcase
        end

        # canonical is nil for a merge into a deleted category; keep looking then.
        def lookup(index, pass, name)
          key = query_key(pass, name)
          return nil if key.nil?

          index.fetch(key, []).each do |row|
            resolved = row.canonical
            # A genre merged into a location must not tag a book with a setting.
            return resolved if resolved && TYPE_ORDER.include?(resolved.category_type)
          end
          nil
        end
      end
    end
  end
end
