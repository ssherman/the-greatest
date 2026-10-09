# frozen_string_literal: true

module Services
  module Books
    module OlBackfill
      # Spec section 4, books:ol_backfill_report: lines of text the rake task prints.
      class Report
        RECENT = 20

        def self.call
          new.call
        end

        def call
          lines = ["Open Library backfill", "", "Outcomes:"]
          counts = rows.group(:outcome).count
          ::Books::OpenLibraryBackfill.outcomes.each_key { |outcome| lines << format("  %-15s %d", outcome, counts.fetch(outcome, 0)) }
          lines << ""
          lines << abstain_line
          lines << ranked_line
          lines << latest_run_line
          lines << latest_failure_line
          lines << author_line
          lines << ""
          lines << "Most recent replaced keys and pairs:"
          lines.concat(recent_lines)
          lines
        end

        private

        def rows = ::Books::OpenLibraryBackfill.all

        def ranked_line
          config = ::Books::RankingConfiguration.default_primary
          ranked = ::RankedItem.where(ranking_configuration_id: config&.id, item_type: "Books::Book").where.not(rank: nil)
          checked = rows.where(book_id: ranked.select(:item_id)).where.not(outcome: :failed).count
          "Ranked books checked: #{checked} of #{ranked.count}"
        end

        def latest_run_line
          latest = rows.order(updated_at: :desc, id: :desc).first
          return "Latest run: none" unless latest

          "Latest run #{latest.run_id}: #{rows.where(run_id: latest.run_id).count} books, last at #{latest.updated_at.iso8601}"
        end

        def abstain_line
          "Confirmed on Open Library's top answer (abstained): #{rows.where(confirmed_on_abstain: true).count}"
        end

        def latest_failure_line
          failure = rows.failed.includes(:book).order(updated_at: :desc, id: :desc).first
          return "Latest failure: none" unless failure

          "Latest failure: book #{failure.book_id} \"#{failure.book.title}\": #{failure.error} at #{failure.updated_at.iso8601}"
        end

        def author_line
          totals = %w[added pairs conflicts].map do |part|
            rows.sum(Arel.sql("jsonb_array_length(COALESCE(author_changes->'#{part}', '[]'::jsonb))")).to_i
          end
          format("Author keys added: %d, author pairs: %d, author conflicts: %d", *totals)
        end

        def recent_lines
          pairs = rows.where(outcome: :confirmed).where.not(pair_book_id: nil)
          recent = rows.where(outcome: %i[replaced duplicate_pair removed]).or(pairs).includes(:book).order(updated_at: :desc, id: :desc).limit(RECENT)
          return ["  none"] if recent.empty?

          recent.map do |row|
            pair = row.pair_book_id ? " (pair with book #{row.pair_book_id})" : ""
            "  #{row.outcome} book #{row.book_id} \"#{row.book.title}\": #{row.old_keys.join(", ").presence || "no key"} -> #{row.new_key.presence || "no key"}#{pair}"
          end
        end
      end
    end
  end
end
