# frozen_string_literal: true

module Services
  module UserLists
    # Sets user_lists.manually_ordered for favorites lists whose item order
    # differs from the order the items were added in -- i.e. the user actually
    # arranged the list rather than just appending to it.
    #
    # This only recovers signal from legacy-imported data. The new app has no
    # reorder UI yet (Phase B of user-lists), so nothing created here can be
    # curated; once that ships it sets the flag directly and this becomes a
    # one-time historical backfill.
    #
    # Detection is one-directional by design: a user who adds books in preference
    # order and never has to move anything is indistinguishable from one who
    # appends carelessly. We under-claim rather than invent a ranking.
    #
    # Only flips false -> true, so it is safe to re-run.
    class BackfillManuallyOrdered
      # list_type 0 is :favorites in every UserList subclass.
      SQL = <<~SQL
        UPDATE user_lists SET manually_ordered = true, updated_at = NOW()
        WHERE manually_ordered = false
          AND id IN (
            SELECT user_list_id FROM (
              SELECT uli.user_list_id,
                row_number() OVER (
                  PARTITION BY uli.user_list_id ORDER BY uli.position, uli.id
                ) AS position_rank,
                row_number() OVER (
                  PARTITION BY uli.user_list_id ORDER BY uli.created_at, uli.id
                ) AS insertion_rank
              FROM user_list_items uli
              JOIN user_lists ul ON ul.id = uli.user_list_id
              WHERE ul.list_type = 0
            ) ranked
            GROUP BY user_list_id
            HAVING count(*) FILTER (WHERE position_rank <> insertion_rank) > 0
          )
      SQL

      def self.call
        new.call
      end

      def call
        ::UserList.connection.exec_update(SQL)
      end
    end
  end
end
