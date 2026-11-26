module Services
  module BooksMigration
    # What one batch of legacy-origin user lists should hold after a sync (spec §6).
    # UserListItemMigrator applies it and UserDataDiff only counts it, so the
    # report and the run agree.
    #
    # Each legacy item's book goes through BookRoute. Two legacy items that land
    # on the same book in one list (a merge) collapse to the one at the lower
    # position. Items on deleted books are dropped, items on books the run has not
    # copied yet wait, and items on :missing books are collected for the caller.
    # Every row here that the plan does not keep is stale: legacy removed it, or a
    # merge or replay relink put it there.
    #
    # The exception is a reader/book pair in the hold (ReimportHold): the Goodreads
    # re-import changed it here on purpose, so legacy's copy is neither kept nor
    # inserted and our row is neither stale nor rewritten. A pair is held across all
    # of the reader's lists (list_users maps list id to user id). Held legacy rows
    # are skipped before the merge-collision check, so a held row never "wins" a
    # collision against a row that should sync.
    class UserListItemPlan
      Plan = Struct.new(:keep, :stale_ids, :inserted, :dropped, :waiting, :collisions, :missing, :held_legacy, :held_here,
        keyword_init: true)

      # legacy_rows: legacy user_list_books attribute hashes (String keys).
      # here_rows: [[id, user_list_id, listable_type, listable_id], ...] for the same lists.
      # list_users is required: without it every pair's reader is nil and the hold silently holds nothing.
      def self.call(legacy_rows, here_rows, route, list_users:, hold: ReimportHold.none)
        keep = {}
        counts = Hash.new(0)
        missing = []
        ordered = legacy_rows.sort_by { |row| [row["position"] || UserListItemMigrator::NULL_POSITION_SENTINEL, row["id"]] }
        ordered.each do |row|
          book_id = route.call(row["book_id"])
          user_id = list_users[row["user_list_id"]]
          if hold.held?(user_id, row["book_id"]) || hold.held?(user_id, book_id)
            counts[:held_legacy] += 1
            next
          end
          case book_id
          when :deleted then counts[:dropped] += 1
          when :waiting then counts[:waiting] += 1
          when :missing then missing << row["id"]
          else
            key = [row["user_list_id"], book_id]
            if keep.key?(key)
              counts[:collisions] += 1
            else
              keep[key] = row
            end
          end
        end

        present = Set.new
        stale_ids = []
        here_rows.each do |id, list_id, type, listable_id|
          if type == "Books::Book" && hold.held?(list_users[list_id], listable_id)
            counts[:held_here] += 1
          elsif type == "Books::Book" && keep.key?([list_id, listable_id])
            present << [list_id, listable_id]
          else
            stale_ids << id
          end
        end

        Plan.new(
          keep: keep, stale_ids: stale_ids, inserted: keep.keys.count { |key| !present.include?(key) },
          dropped: counts[:dropped], waiting: counts[:waiting], collisions: counts[:collisions], missing: missing,
          held_legacy: counts[:held_legacy], held_here: counts[:held_here]
        )
      end
    end
  end
end
