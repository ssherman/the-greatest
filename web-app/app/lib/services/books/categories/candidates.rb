# frozen_string_literal: true

module Services
  module Books
    module Categories
      # Retrieves the categories a free-text name could mean, scored in Ruby with
      # Trigram (see there). Loads the type's active names and their trigram profiles once per instance; the
      # category table is small, and no database extension or index is involved.
      # Retrieval only: the AI task rules on the candidates.
      class Candidates
        MIN_SIMILARITY = 0.3
        # Recall over precision: a query that is a whole word inside a longer name
        # (Paris in Parisian Suburbs) must still surface.
        MIN_WORD_SIMILARITY = 0.5
        FICTIONAL_ROOT = "Fictional Location"

        def initialize(category_type:)
          @category_type = category_type.to_s
        end

        # fictional: true keeps only the Fictional Location subtree, false drops it;
        # nil leaves locations unfiltered. Only meaningful for the "location" type.
        def call(name:, fictional: nil, limit: 10)
          fictional_set = (@category_type == "location" && !fictional.nil?) ? self.class.fictional_ids : nil

          query = Trigram.profile(name)
          scored = rows.filter_map do |id, profile|
            next if fictional_set && fictional_set.include?(id) != fictional

            sim = Trigram.similarity_of(profile, query)
            word = Trigram.word_similarity_of(query, profile)
            next unless sim > MIN_SIMILARITY || word > MIN_WORD_SIMILARITY

            [[sim, word].max, id]
          end

          ids = scored.sort_by { |score, id| [-score, id] }.first(limit).map(&:last)
          by_id = ::Books::Category.where(id: ids).index_by(&:id)
          ids.filter_map { |id| by_id[id] }
        end

        # The Fictional Location root and its active descendants. Empty when the root is absent.
        def self.fictional_ids
          root = ::Books::Category.active.location.find_by(name: FICTIONAL_ROOT)
          return Set.new unless root

          location_type = ::Books::Category.category_types.fetch("location").to_i
          sql = <<~SQL.squish
            WITH RECURSIVE tree(id) AS (
              SELECT id FROM categories WHERE id = #{root.id.to_i}
              UNION
              SELECT c.id FROM categories c
              JOIN tree ON c.parent_id = tree.id
              WHERE c.type = 'Books::Category' AND c.category_type = #{location_type} AND c.deleted = FALSE
            )
            SELECT id FROM tree
          SQL
          ::Books::Category.connection.select_values(sql).to_set
        end

        private

        def rows
          @rows ||= ::Books::Category.active.where(category_type: @category_type).pluck(:id, :name)
            .map { |id, row_name| [id, Trigram.profile(row_name)] }
        end
      end
    end
  end
end
