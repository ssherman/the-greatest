# frozen_string_literal: true

module Categories
  # Keeps inherited location links consistent (spec §3.3). A book linked
  # directly to Chicago also carries `inherited` links to Illinois, United
  # States and North America; when the Chicago link goes, so do the inherited
  # links nothing else still needs. Set-based SQL over a recursive CTE of the
  # books location tree, so a whole-catalog run is two statements.
  #
  # Callers: admin add/remove category, Merger, Deleter, the book merger, the
  # weekly sync, cleanup apply, the over-tagged trim. Idempotent.
  class AncestorReconciler
    Result = Struct.new(:success?, :data, :errors, keyword_init: true)

    ITEM_TYPE = "Books::Book"

    def self.call(item_ids: nil)
      new(item_ids: item_ids).call
    end

    def initialize(item_ids: nil)
      @item_ids = item_ids&.map(&:to_i)&.uniq
    end

    def call
      return result(0, 0) if @item_ids && @item_ids.empty?

      added = removed = nil
      ::CategoryItem.transaction do
        added = aggregate(insert_sql)
        removed = aggregate(delete_sql)
        # Inside the transaction so a crash can't leave item_count stale.
        ItemCounter.call(added[:category_ids] | removed[:category_ids])
      end

      # Every row touched is a Books::Book link (ITEM_TYPE).
      ItemReindexer.queue_items((added[:item_ids] | removed[:item_ids]).map { |id| [ITEM_TYPE, id] })
      result(added[:count], removed[:count])
    end

    private

    def result(added, removed)
      Result.new(success?: true, data: {added: added, removed: removed}, errors: [])
    end

    # Runs a statement that ends in summary_select and returns its aggregate, so
    # a whole-catalog run never materialises the changed rows in Ruby.
    # cast_values decodes the Postgres arrays through the adapter's type map.
    def aggregate(sql)
      count, category_ids, item_ids = ::CategoryItem.connection.select_all(sql).cast_values.first
      {count: count.to_i, category_ids: Array(category_ids), item_ids: Array(item_ids)}
    end

    def summary_select
      "SELECT COUNT(*) AS n, ARRAY_AGG(DISTINCT category_id) AS category_ids, " \
        "ARRAY_AGG(DISTINCT item_id) AS item_ids FROM changed"
    end

    def inherited = ::CategoryItem.sources.fetch("inherited")

    def location = ::Category.category_types.fetch("location")

    def item_filter(table)
      return "" if @item_ids.nil?

      "AND #{table}.item_id IN (#{@item_ids.join(",")})"
    end

    # (descendant_id, ancestor_id) for every live books location and every live
    # books-location ancestor above it. A soft-deleted or foreign parent ends the chain.
    def ancestry_cte
      <<~SQL
        WITH RECURSIVE ancestry(descendant_id, ancestor_id, depth) AS (
          SELECT c.id, p.id, 1
          FROM categories c
          JOIN categories p ON p.id = c.parent_id AND p.deleted = false
            AND p.type = 'Books::Category' AND p.category_type = #{location}
          WHERE c.type = 'Books::Category' AND c.category_type = #{location} AND c.deleted = false
          UNION ALL
          SELECT a.descendant_id, p.id, a.depth + 1
          FROM ancestry a
          JOIN categories c ON c.id = a.ancestor_id
          JOIN categories p ON p.id = c.parent_id AND p.deleted = false
            AND p.type = 'Books::Category' AND p.category_type = #{location}
          WHERE a.depth < #{::Books::Category::MAX_DEPTH}
        )
      SQL
    end

    def insert_sql
      <<~SQL
        #{ancestry_cte},
        changed AS (
          INSERT INTO category_items (category_id, item_type, item_id, source, created_at, updated_at)
          SELECT DISTINCT a.ancestor_id, d.item_type, d.item_id, #{inherited}, NOW(), NOW()
          FROM category_items d
          JOIN ancestry a ON a.descendant_id = d.category_id
          WHERE d.item_type = '#{ITEM_TYPE}' AND d.source <> #{inherited} #{item_filter("d")}
          ON CONFLICT (category_id, item_type, item_id) DO NOTHING
          RETURNING category_id, item_id
        )
        #{summary_select}
      SQL
    end

    def delete_sql
      <<~SQL
        #{ancestry_cte},
        changed AS (
          DELETE FROM category_items i
          USING categories c
          WHERE c.id = i.category_id AND c.type = 'Books::Category'
            AND i.item_type = '#{ITEM_TYPE}' AND i.source = #{inherited} #{item_filter("i")}
            AND NOT EXISTS (
              SELECT 1
              FROM category_items d
              JOIN ancestry a ON a.descendant_id = d.category_id
              WHERE d.item_type = i.item_type AND d.item_id = i.item_id
                AND d.source <> #{inherited} AND a.ancestor_id = i.category_id
            )
          RETURNING i.category_id, i.item_id
        )
        #{summary_select}
      SQL
    end
  end
end
