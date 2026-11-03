# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      # Decides what one Goodreads CSV row does to the user's lists and records it as a reimport_row verdict
      # (re-import spec 4.5): keep the entry where legacy put it, move it, copy it (legacy put two editions on one
      # book), or add it. A row waits, recording nothing, until its edition's match is approved and applied, and
      # until every sibling row that legacy put on the same book has a destination too, because "move" versus
      # "copy" depends on where the siblings go.
      #
      # The same edition in a newer completed import of the same user supersedes this row: the older one is
      # recorded as a "keep" naming the newer row, and apply changes nothing for it.
      class DecideRow
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        def self.call(row:)
          new(row: row).call
        end

        def initialize(row:)
          @row = row
        end

        def call
          destination = destination_for(@row.goodreads_edition_id)
          return done(:waiting) if destination.nil?

          newer = newer_row_for(@row)
          return record(action: "keep", to: destination, superseded_by: row_key(newer), review: false) if newer

          action = action_for(destination)
          return done(:waiting) if action.nil?

          record(action: action, to: destination, review: carries_review?(destination))
        end

        private

        def user_rows
          @user_rows ||= ::Books::GoodreadsImportRow
            .joins(:import).merge(::Books::GoodreadsImport.legacy_replay.complete)
            .where(books_goodreads_imports: {user_id: @row.import.user_id})
            .includes(:import).to_a
        end

        # A match's destination exists only once it is approved, current and applied.
        def destinations
          @destinations ||= begin
            edition_ids = user_rows.filter_map(&:goodreads_edition_id).uniq
            ::Books::RepairVerdict.reimport_match.approved.current.where.not(applied_at: nil)
              .where(subject_key: edition_ids.map { |id| "reimport:edition:#{id}" })
              .each_with_object({}) do |verdict, found|
                book_id = verdict.payload["book_id"] || verdict.payload["created_book_id"]
                found[verdict.subject_key.delete_prefix("reimport:edition:").to_i] = book_id if book_id
              end
          end
        end

        def destination_for(edition_id) = destinations[edition_id]

        def import_order(row) = [row.import.finished_at || row.import.created_at, row.import.id]

        def row_order(row) = [import_order(row), row.row_number]

        def row_key(row) = "reimport:row:#{row.import_id}:#{row.row_number}"

        def newer_row_for(row)
          return nil if row.goodreads_edition_id.nil?

          user_rows.select { |other| other.goodreads_edition_id == row.goodreads_edition_id && (import_order(other) <=> import_order(row)) == 1 }
            .max_by { |other| row_order(other) }
        end

        def live_rows
          @live_rows ||= user_rows.select { |other| other.goodreads_edition_id && newer_row_for(other).nil? }
        end

        def from_book
          return @from_book if defined?(@from_book)

          @from_book = @row.legacy_book_id && ::Services::Books::GoodreadsReplay::Apply::MergedBook.call(@row.legacy_book_id)
        end

        # Rows of the user that legacy put on the same book as this one. If they do not all go to one destination,
        # each gets its own copy. Nil means a sibling has no destination yet, so the row waits.
        def action_for(destination)
          return "add" if from_book.nil?

          group = live_rows.select { |other| other.legacy_book_id == @row.legacy_book_id }
            .map { |other| destination_for(other.goodreads_edition_id) }
          return nil if group.any?(&:nil?)
          return "copy" if (group + [destination]).uniq.size > 1

          (from_book.id == destination) ? "keep" : "move"
        end

        # One row per user per destination carries the review: the newest one that has anything to carry.
        def carries_review?(destination)
          candidates = live_rows.select do |other|
            destination_for(other.goodreads_edition_id) == destination && (other.rating.to_f > 0 || other.review_body.present?)
          end
          candidates.max_by { |other| row_order(other) }&.id == @row.id
        end

        def record(action:, to:, review:, superseded_by: nil)
          payload = {
            "import_id" => @row.import_id, "row_number" => @row.row_number, "user_id" => @row.import.user_id,
            "goodreads_edition_id" => @row.goodreads_edition_id, "action" => action,
            "from_book_id" => from_book&.id, "to_book_id" => to, "review" => review, "superseded_by" => superseded_by
          }
          # Moving a trusted book's only entry away is the one change a person looks at first.
          auto = !(action == "move" && ::Services::Books::GoodreadsRebuild::Cohort.trusted?(from_book.id))
          recorded = ::Services::Books::GoodreadsReplay::RecordVerdict.call(
            kind: :reimport_row, subject_key: row_key(@row), payload: payload, decided_by: :rule, auto: auto, replace_superseded: true
          )
          outcome = %i[kept suppressed].include?(recorded.data[:outcome]) ? :kept : :recorded
          done(outcome, recorded.data[:verdict])
        end

        def done(outcome, verdict = nil)
          Result.new(success?: true, data: {outcome: outcome, verdict: verdict}, errors: [])
        end
      end
    end
  end
end
