# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Undoes a second chance: puts the book back the way it was when the
      # `second_chance` run took it, so the row is `unsure` or `removed` again
      # and a later second_chance run can take it fresh. Reuses Revert's
      # finding logic; only what the second chance wrote (findings and
      # edition candidates created at or after second_chance_at) is undone.
      class RevertSecondChance < Revert
        # The row keeps its run_id, so a re-queue under the same second-chance
        # run id will not retake it; a new run will.
        # A duplicate_pair settle (the route's work is held by another book) is
        # reverted like a keyed one.
        SETTLED = (::Books::Verification::KEYED_OUTCOMES + %w[duplicate_pair]).freeze
        # The one list of routes; Report uses it too.
        ROUTES = %w[resolve_candidate exact_title held_key worldcat_isbns].freeze
        # Not a lookup value: the rows a second_chance run settled through Open
        # Library's own matcher (identifiers or resolve), which the title-key
        # fix can now let pass.
        MATCHER_ROUTE = "second_chance_matcher"
        REVERTIBLE_ROUTES = (ROUTES + [MATCHER_ROUTE]).freeze

        # The rows a second_chance run settled through the matcher.
        def self.matcher_settled
          ::Books::Verification.where.not(second_chance_at: nil).where(lookup: ApplyBook::MATCHER_LOOKUPS, work_outcome: SETTLED)
        end

        # A row the second chance settled: this revert, not the full one, is its undo.
        def self.applies_to?(row)
          row.present? && row.second_chance_at.present? && SETTLED.include?(row.work_outcome)
        end

        # Reverts every row a route settled. A row with no second_chance_at was
        # settled on a first pass (routes run on every stage-1 pass), so it
        # takes the full Revert instead.
        def self.route(lookup)
          lookup = lookup.to_s
          raise ArgumentError, "unknown route #{lookup.inspect}; use #{REVERTIBLE_ROUTES.join(", ")}" unless REVERTIBLE_ROUTES.include?(lookup)

          scope = (lookup == MATCHER_ROUTE) ? matcher_settled : ::Books::Verification.where(lookup: lookup, work_outcome: SETTLED)
          counts = {reverted: 0, failed: 0}
          scope.includes(:book).find_each do |row|
            result = row.second_chance_at ? call(book: row.book) : Revert.call(book: row.book)
            counts[result.success? ? :reverted : :failed] += 1
          end
          counts
        end

        def call
          row = ::Books::Verification.find_by(book: @book)
          return failure("book #{@book.id} has no backfill row") unless row
          return failure("book #{@book.id} has no second chance to revert") unless row.second_chance_at
          unless SETTLED.include?(row.work_outcome)
            return failure("book #{@book.id} is #{row.work_outcome}; the second chance did not settle it")
          end

          skipped = 0
          ::ActiveRecord::Base.transaction do
            restore_prior_keys(row)
            @book.identifiers.where(identifier_type: ApplyBook::DUPLICATE_KEY, value: row.duplicate_keys).destroy_all
            # A matcher settle (identifiers or resolve) may have given authors keys.
            revert_author_keys(row)
            skipped = revert_findings(row, row.findings.where(created_at: row.second_chance_at..))
            ::Books::EditionCandidate.where(book_id: @book.id, created_at: row.second_chance_at..).delete_all
            row.update!(work_outcome: row.prior_outcome, lookup: :resolve, new_key: nil, duplicate_keys: [], pair_book_id: nil,
              author_changes: {}, stage: :done, lump_suspect: false, second_chance_at: nil, prior_outcome: nil, prior_keys: [])
            Counts.call(row)
          end
          Result.new(success?: true, data: {row: row, skipped: skipped}, errors: [])
        end

        private

        # prior_keys, not old_keys: a removed row's removed key stays gone. The
        # key the second chance added goes; a prior key it confirmed goes back
        # to legacy.
        def restore_prior_keys(row)
          held = @book.identifiers.where(identifier_type: ApplyBook::WORK_KEY)
          held.where(value: row.new_key).destroy_all if row.new_key.present? && !row.prior_keys.include?(row.new_key)
          held.where(value: row.prior_keys).update_all(source: ::Identifier.sources[:legacy], updated_at: Time.current)
          (row.prior_keys - held.reload.pluck(:value)).each do |key|
            @book.identifiers.create!(identifier_type: ApplyBook::WORK_KEY, value: key, source: :legacy)
          end
        end
      end
    end
  end
end
