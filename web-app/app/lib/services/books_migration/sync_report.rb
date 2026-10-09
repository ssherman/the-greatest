module Services
  module BooksMigration
    # Prints a SyncPlan's report (spec §7): what data_migration:sync would do now.
    class SyncReport
      SHOWN_IDS = 20
      COLUMNS = "%-32s %10s %10s %14s %16s"

      def self.render(plan)
        new(plan.report).render
      end

      def initialize(report)
        @report = report
      end

      def render
        [
          header,
          format(COLUMNS, "Catalog", "legacy", "here", "would insert", "waiting (<24h)"),
          record_line("books (above watermark)", @report[:books]),
          record_line("authors", @report[:authors]),
          format("  %-30s %10s %10s %14s %16s", "book_identifiers (new)", "", "", number(@report[:book_identifiers][:would_insert]), number(@report[:book_identifiers][:waiting])),
          "  categories (unmapped): #{number(@report[:categories_unmapped])}",
          "  skipped (redirected): books #{@report[:books][:skipped_redirected]}, authors #{@report[:authors][:skipped_redirected]}",
          "  legacy deleted, still here: books #{ids(@report[:books][:legacy_deleted_still_here])}; " \
            "authors #{ids(@report[:authors][:legacy_deleted_still_here])}",
          "  redirects recorded: #{redirects}",
          "  legacy edits to existing books, not synced: #{number(@report[:legacy_edits_not_synced])}"
        ].join("\n")
      end

      private

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
