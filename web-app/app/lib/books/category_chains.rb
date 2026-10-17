module Books
  # Parent chains for a whole page of category cards in ONE query.
  #
  # Books::Category#ancestors walks one query per level per card, so rendering
  # "Europe > France > Ile-de-France" under every card of a 48-card page would
  # cost hundreds of queries. This walks upward from every card's parent with a
  # single recursive CTE and then assembles each chain in memory. Never call
  # Category#ancestors per card.
  #
  #   chains = Books::CategoryChains.call(categories)
  #   chains.fetch(category.id, [])  # => ["Europe", "France"]  (root first)
  #
  # Only categories with a non-empty chain get a key. A soft-deleted ancestor
  # ends the chain, and MAX_DEPTH plus a revisit check stop a parent cycle
  # written around the validation (raw SQL) from looping.
  class CategoryChains
    MAX_DEPTH = ::Books::Category::MAX_DEPTH

    SQL = <<~SQL.squish.freeze
      WITH RECURSIVE chain(id, name, parent_id, depth) AS (
        SELECT id, name, parent_id, 1
        FROM categories
        WHERE id IN (?) AND deleted = FALSE
        UNION ALL
        SELECT c.id, c.name, c.parent_id, chain.depth + 1
        FROM categories c
        JOIN chain ON c.id = chain.parent_id
        WHERE c.deleted = FALSE AND chain.depth < ?
      )
      SELECT DISTINCT id, name, parent_id FROM chain
    SQL

    def self.call(categories)
      new(categories).call
    end

    def initialize(categories)
      @categories = categories.to_a
    end

    def call
      parent_ids = @categories.filter_map(&:parent_id).uniq
      return {} if parent_ids.empty?

      nodes = load_nodes(parent_ids)
      @categories.each_with_object({}) do |category, chains|
        chain = names_above(category.parent_id, nodes)
        chains[category.id] = chain if chain.any?
      end
    end

    private

    def load_nodes(parent_ids)
      rows = ::Books::Category.find_by_sql([SQL, parent_ids, MAX_DEPTH])
      rows.to_h { |row| [row.id, [row.name, row.parent_id]] }
    end

    # Nearest first while walking, reversed to root first for display.
    def names_above(parent_id, nodes)
      names = []
      seen = Set.new
      while parent_id && names.size < MAX_DEPTH && seen.add?(parent_id) && (node = nodes[parent_id])
        names << node[0]
        parent_id = node[1]
      end
      names.reverse
    end
  end
end
