module Services
  module BooksMigration
    # Prints a SyncPlan's report (spec §7): what data_migration:sync would do now,
    # and, given UserDataDiff's numbers, the user-data half.
    class SyncReport
      SHOWN_IDS = 20
      COLUMNS = "%-32s %10s %10s %14s %16s"
      USER_COLUMNS = "%-24s %10s %10s %8s %8s %8s %8s %8s  %s"
      USER_KEYS = %i[legacy here inserted updated deleted dropped waiting].freeze

      def self.render(plan, user_data: nil)
        new(plan.report, user_data).render
      end

      def initialize(report, user_data = nil)
        @report = report
        @user_data = user_data
      end

      def render
        lines = [
          header,
          format(COLUMNS, "Catalog", "legacy", "here", "would insert", "waiting (<24h)"),
          record_line("books (above watermark)", @report[:books]),
          record_line("authors", @report[:authors]),
          format("  %-30s %10s %10s %14s %16s", "book_identifiers (new legacy rows; deduped on insert)", "", "", number(@report[:book_identifiers][:would_insert]), number(@report[:book_identifiers][:waiting])),
          "  categories (unmapped): #{number(@report[:categories_unmapped])}",
          "  skipped (redirected): books #{@report[:books][:skipped_redirected]}, authors #{@report[:authors][:skipped_redirected]}",
          "  legacy deleted, still here: books #{ids(@report[:books][:legacy_deleted_still_here])}; " \
            "authors #{ids(@report[:authors][:legacy_deleted_still_here])}",
          "  redirects recorded: #{redirects}",
          "  legacy edits to existing books, not synced: #{number(@report[:legacy_edits_not_synced])}"
        ]
        lines += ["", *user_data_lines] if @user_data
        lines.join("\n")
      end

      private

      def user_data_lines
        data = @user_data
        [
          format(USER_COLUMNS, "User data", "legacy", "here", "insert", "update", "delete", "dropped", "waiting", ""),
          user_line("users", data[:users], "#{number(data[:users][:deleted_on_legacy])} deleted on legacy (counted, not applied)"),
          user_line("user_lists", data[:user_lists]),
          user_line("user_list_items", data[:user_list_items], "#{number(data[:user_list_items][:collisions])} merge collisions"),
          user_line("reviews", data[:reviews],
            "#{number(data[:reviews][:collisions])} collisions, #{number(data[:reviews][:held_by_new_app])} held by a new-app review"),
          user_line("saved_searches", data[:saved_searches],
            "#{number(data[:saved_searches][:categories_removed])} deleted categories removed from criteria"),
          user_line("reading_goals", data[:reading_goals]),
          user_line("recommendation_configs", data[:recommendation_configs]),
          user_line("corrections", data[:corrections], "#{number(data[:corrections][:missing])} on books not here (skipped)"),
          missing_line
        ].compact
      end

      def user_line(label, counts, note = "")
        values = USER_KEYS.map { |key| counts.key?(key) ? number(counts[key]) : "—" }
        format(USER_COLUMNS, "  #{label}", *values, note)
      end

      # List items and reviews on a book that is neither here nor redirected
      # fail the sync (a book removed without callbacks), so say so up front.
      def missing_line
        missing = @user_data[:user_list_items][:missing] + @user_data[:reviews][:missing]
        return if missing.zero?

        "  MISSING: #{number(missing)} list items or reviews name a book that is neither here nor redirected; " \
          "the sync will fail on them"
      end

      def header
        return "Before sync_init: the highest legacy-origin ids here stand in for the watermarks." unless @report[:initialized]

        "Watermarks: " + @report[:watermarks].map { |key, value| "#{key} #{number(value)}" }.join(", ")
      end

      def record_line(label, counts)
        format("  %-30s %10s %10s %14s %16s", label, number(counts[:legacy]), number(counts[:here]),
          number(counts[:would_insert]), number(counts[:waiting]))
      end

      def ids(list)
        return "0" if list.empty?

        shown = list.first(SHOWN_IDS).join(", ")
        more = (list.size > SHOWN_IDS) ? ", and #{list.size - SHOWN_IDS} more" : ""
        "#{list.size} (ids: #{shown}#{more})"
      end

      def redirects
        @report[:redirects].map do |item_type, counts|
          "#{(item_type == "Books::Book") ? "books" : "authors"} merged #{counts[:merged]}, deleted #{counts[:deleted]}"
        end.join("; ")
      end

      def number(value)
        value.nil? ? "n/a before sync_init" : ActiveSupport::NumberHelper.number_to_delimited(value)
      end
    end
  end
end
