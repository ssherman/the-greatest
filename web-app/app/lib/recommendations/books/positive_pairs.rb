# frozen_string_literal: true

module Recommendations
  module Books
    # Every (user, book) positive pair for the collaborative export (spec 2
    # §3): favorites, read and reading list items, and reviews rated at the
    # floor. One UNION streamed through a server-side cursor, sorted so the
    # export file is deterministic. Root-anchored constants: inside
    # Recommendations::Books a bare Books::UserList resolves wrongly.
    class PositivePairs
      LIST_TYPES = %w[favorites read reading].freeze

      def initialize(min_rating:)
        @min_rating = min_rating.to_i
      end

      def each_batch(batch_size: 50_000)
        conn = ::ActiveRecord::Base.connection
        conn.transaction do
          conn.execute("DECLARE recommendation_positive_pairs NO SCROLL CURSOR FOR #{sql}")
          loop do
            # uncached: the query cache would replay the identical FETCH text forever
            rows = conn.uncached { conn.select_rows("FETCH FORWARD #{batch_size.to_i} FROM recommendation_positive_pairs") }
            break if rows.empty?

            yield rows.map { |user_id, item_id| [user_id.to_i, item_id.to_i] }
          end
          conn.execute("CLOSE recommendation_positive_pairs")
        end
      end

      private

      def sql
        list_types = LIST_TYPES.map { |name| ::Books::UserList.list_types.fetch(name) }.join(", ")
        <<~SQL
          SELECT user_id, item_id FROM (
            SELECT ul.user_id AS user_id, uli.listable_id AS item_id
              FROM user_list_items uli
              JOIN user_lists ul ON ul.id = uli.user_list_id
             WHERE ul.type = 'Books::UserList'
               AND uli.listable_type = 'Books::Book'
               AND ul.list_type IN (#{list_types})
            UNION
            SELECT user_id, reviewable_id
              FROM reviews
             WHERE reviewable_type = 'Books::Book'
               AND rating >= #{@min_rating}
          ) pairs
          ORDER BY user_id, item_id
        SQL
      end
    end
  end
end
