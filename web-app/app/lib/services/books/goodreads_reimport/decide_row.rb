# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReimport
      # Decides what a user's Goodreads CSV rows do to their lists and records each as a reimport_row verdict
      # (re-import spec 4.5): keep the entry where legacy put it, move it, copy it (legacy put two editions on one
      # book), or add it.
      #
      # A user's rows are decided together or not at all. Move versus copy and the review all depend on where the
      # user's other rows go, so until every live row of the user has a destination (an approved, applied
      # reimport_match) every row of the user waits and nothing is recorded. Rows whose edition's match was
      # rejected never resolve on their own, so they are left out of that check and wait by themselves.
      #
      # The same edition in a newer completed import of the same user supersedes the older row: it is recorded as
      # a "keep" naming the newer row, and apply changes nothing for it.
      #
      # An applied verdict is final. If today's decision for it differs, nothing is written and the row reports
      # :conflict, because the lists have already been changed on the strength of the old answer.
      class DecideRow
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        COMPARED = %w[action to_book_id from_book_id review].freeze

        def self.call(row:)
          user = decide_user(user_id: row.import.user_id)
          outcome, verdict = user.data[:by_row][row.id] || [:waiting, nil]
          Result.new(success?: true, data: {outcome: outcome, verdict: verdict}, errors: [])
        end

        # data: {tally: {outcome => count}, by_row: {row_id => [outcome, verdict]}}
        def self.decide_user(user_id:)
          new(user_id: user_id).call
        end

        def initialize(user_id:)
          @user_id = user_id
        end

        def call
          @by_row = {}
          if rows.any? { |row| decidable?(row) && live?(row) && destination(row).nil? }
            rows.each { |row| @by_row[row.id] = [:waiting, nil] }
          else
            decisions = rows.to_h { |row| [row.id, decision_for(row)] }
            conflicted = conflicted_groups(decisions)
            rows.each do |row|
              @by_row[row.id] = if rejected?(row)
                [:waiting, nil]
              elsif conflicted.include?(from_id(row))
                [:conflict, existing[row_key(row)]]
              else
                settle(row, decisions[row.id])
              end
            end
          end
          tally = @by_row.values.map(&:first).tally
          Result.new(success?: true, data: {tally: tally, by_row: @by_row}, errors: [])
        end

        private

        def rows
          @rows ||= ::Books::GoodreadsImportRow
            .joins(:import).merge(::Books::GoodreadsImport.legacy_replay.complete)
            .where(books_goodreads_imports: {user_id: @user_id}).where.not(goodreads_edition_id: nil)
            .includes(:import).to_a
        end

        def matches
          @matches ||= ::Books::RepairVerdict.reimport_match.current
            .where(subject_key: rows.map { |row| "reimport:edition:#{row.goodreads_edition_id}" }.uniq)
            .index_by { |verdict| verdict.subject_key.delete_prefix("reimport:edition:").to_i }
        end

        # A destination exists only once the match is approved, current and applied.
        def destination(row)
          match = matches[row.goodreads_edition_id]
          return nil unless match&.approved? && match.applied_at
          match.payload["book_id"] || match.payload["created_book_id"]
        end

        def rejected?(row) = matches[row.goodreads_edition_id]&.rejected?

        def decidable?(row) = !rejected?(row)

        def existing
          @existing ||= ::Books::RepairVerdict.reimport_row.where(subject_key: rows.map { |row| row_key(row) }).index_by(&:subject_key)
        end

        def row_key(row) = "reimport:row:#{row.import_id}:#{row.row_number}"

        def import_order(row) = [row.import.finished_at || row.import.created_at, row.import.id]

        # Newest import first, then the lowest row number.
        def preference(row) = [import_order(row), -row.row_number]

        def superseded_by(row)
          @superseded_by ||= {}
          return @superseded_by[row.id] if @superseded_by.key?(row.id)

          @superseded_by[row.id] = rows.select { |other| other.goodreads_edition_id == row.goodreads_edition_id && (import_order(other) <=> import_order(row)) == 1 }
            .max_by { |other| preference(other) }
        end

        def live?(row) = superseded_by(row).nil?

        def live_rows = @live_rows ||= rows.select { |row| decidable?(row) && live?(row) }

        def from_id(row)
          @from_ids ||= {}
          return nil if row.legacy_book_id.nil?

          @from_ids.fetch(row.legacy_book_id) do
            @from_ids[row.legacy_book_id] = ::Services::Books::GoodreadsReplay::Apply::MergedBook.call(row.legacy_book_id)&.id
          end
        end

        def has_content?(row) = row.rating.to_f > 0 || row.review_body.present?

        def decision_for(row)
          return nil if rejected?(row)

          newer = superseded_by(row)
          if newer
            {"action" => "keep", "from_book_id" => nil, "to_book_id" => destination(row), "review" => false, "superseded_by" => row_key(newer)}
          else
            live_decision(row)
          end
        end

        def unchanged?(row, decision)
          current = existing[row_key(row)]
          current.nil? || current.applied_at.nil? || COMPARED.all? { |field| current.payload[field] == decision[field] }
        end

        # Rows legacy put on one book share a single entry and review there, so once one of them has been applied a
        # changed answer for any of them makes the whole group unsafe: its unapplied siblings could double-carry the
        # review or move an entry the applied row already took. Rows with no legacy book stand alone.
        def conflicted_groups(decisions)
          rows.select { |row| decisions[row.id] && from_id(row) && !unchanged?(row, decisions[row.id]) }.map do |row|
            Rails.logger.warn("decide_row: #{row_key(row)} already applied as #{existing[row_key(row)].payload.slice(*COMPARED)}, " \
              "now decided #{decisions[row.id].slice(*COMPARED)}; its whole group is left alone")
            from_id(row)
          end.to_set
        end

        def live_decision(row)
          to = destination(row)
          from = from_id(row)
          action = if from.nil?
            "add"
          elsif (live_rows.select { |other| from_id(other) == from }.map { |other| destination(other) } + [to]).uniq.size > 1
            "copy"
          else
            (from == to) ? "keep" : "move"
          end
          {"action" => action, "from_book_id" => from, "to_book_id" => to, "review" => carries_review?(row, from, to), "superseded_by" => nil}
        end

        # With a from-book the flag means "this user's existing review on it goes with this row", so exactly one
        # row per (user, from-book) carries it. Without one it means "write this row's rating/review", one per
        # (user, destination), and none when no row has anything to write.
        def carries_review?(row, from, to)
          if from.nil?
            group = live_rows.select { |other| from_id(other).nil? && destination(other) == to && has_content?(other) }
          else
            group = live_rows.select { |other| from_id(other) == from }
            with_content = group.select { |other| has_content?(other) }
            group = with_content.presence || [group.max_by { |other| [import_order(other), -other.row_number] }]
          end
          group.max_by { |other| preference(other) }&.id == row.id
        end

        def settle(row, decision)
          key = row_key(row)
          current = existing[key]
          if current&.applied_at
            return [:kept, current] if unchanged?(row, decision)

            Rails.logger.warn("decide_row: #{key} already applied as #{current.payload.slice(*COMPARED)}, now decided #{decision.slice(*COMPARED)}; left alone")
            return [:conflict, current]
          end

          payload = {"import_id" => row.import_id, "row_number" => row.row_number, "user_id" => @user_id,
                     "goodreads_edition_id" => row.goodreads_edition_id}.merge(decision)
          # Moving an entry off a trusted book is the one change a person looks at first. A user has at most one
          # entry per book per list, so a move off it always removes their only one there.
          auto = !(decision["action"] == "move" && ::Services::Books::GoodreadsRebuild::Cohort.trusted?(decision["from_book_id"]))
          recorded = ::Services::Books::GoodreadsReplay::RecordVerdict.call(
            kind: :reimport_row, subject_key: key, payload: payload, decided_by: :rule, auto: auto, replace_superseded: true
          )
          outcome = %i[kept suppressed].include?(recorded.data[:outcome]) ? :kept : :recorded
          [outcome, recorded.data[:verdict]]
        end
      end
    end
  end
end
