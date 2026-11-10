# frozen_string_literal: true

module Services
  module Books
    module Categories
      # Retrieves the categories a free-text name could mean, by trigram
      # similarity over lower(name) (served by index_categories_on_lower_name_trgm).
      # Retrieval only: the AI task rules on the candidates, this never picks one.
      class Candidates
        MIN_SIMILARITY = 0.3
        # Recall over precision: the chooser rules on the candidates, so a query that is a
        # whole word inside a longer name (Paris in Parisian Suburbs) must still surface.
        MIN_WORD_SIMILARITY = 0.5
        FICTIONAL_ROOT = "Fictional Location"

        # fictional: true keeps only the Fictional Location subtree, false drops it;
        # nil leaves locations unfiltered. Only meaningful for category_type "location".
        def self.call(name:, category_type:, fictional: nil, limit: 10)
          scope = ::Books::Category.active.where(category_type: category_type)
            .where("similarity(lower(categories.name), lower(?)) > ? OR word_similarity(lower(?), lower(categories.name)) > ?",
              name, MIN_SIMILARITY, name, MIN_WORD_SIMILARITY)

          if category_type.to_s == "location" && !fictional.nil?
            ids = fictional_ids.to_a
            scope = fictional ? scope.where(id: ids) : scope.where.not(id: ids)
          end

          order = ::Books::Category.sanitize_sql_array(["GREATEST(similarity(lower(categories.name), lower(?)), word_similarity(lower(?), lower(categories.name))) DESC, categories.id", name, name])
          scope.order(Arel.sql(order)).limit(limit).to_a
        end

        # The Fictional Location root and its active descendants. Empty when the root is absent.
        def self.fictional_ids
          root = ::Books::Category.active.location.find_by(name: FICTIONAL_ROOT)
          return Set.new unless root

          sql = <<~SQL.squish
            WITH RECURSIVE tree(id) AS (
              SELECT id FROM categories WHERE id = #{root.id.to_i}
              UNION
              SELECT c.id FROM categories c
              JOIN tree ON c.parent_id = tree.id
              WHERE c.type = 'Books::Category' AND c.deleted = FALSE
            )
            SELECT id FROM tree
          SQL
          ::Books::Category.connection.select_values(sql).to_set
        end
      end
    end
  end
end
