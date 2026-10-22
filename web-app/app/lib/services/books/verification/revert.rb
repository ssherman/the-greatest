# frozen_string_literal: true

module Services
  module Books
    module Verification
      # Spec section 4, books:verify_revert: put a book's keys back the
      # way they were before the backfill. The row becomes `reverted`, which
      # no later run takes again.
      class Revert
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        REVERTIBLE = (::Books::Verification.work_outcomes.keys - %w[failed reverted]).freeze
        # Only these outcomes changed work keys, duplicate keys or author keys.
        KEY_REVERTIBLE = (::Books::Verification::KEYED_OUTCOMES + %w[removed]).freeze

        def self.call(book:)
          new(book).call
        end

        def initialize(book)
          @book = book
        end

        def call
          row = ::Books::Verification.find_by(book: @book)
          return failure("book #{@book.id} has no backfill row") unless row
          unless REVERTIBLE.include?(row.work_outcome)
            return failure("book #{@book.id} is #{row.work_outcome}; only #{REVERTIBLE.join(", ")} can be reverted")
          end

          skipped = 0
          ::ActiveRecord::Base.transaction do
            revert_keys(row) if KEY_REVERTIBLE.include?(row.work_outcome)
            skipped = revert_findings(row)
            ::Books::EditionCandidate.where(book_id: @book.id).delete_all
            row.update!(work_outcome: :reverted, stage: :done, lump_suspect: false, added_count: 0, confirmed_count: 0,
              candidate_count: 0, wrong_count: 0)
          end
          Result.new(success?: true, data: {row: row, skipped: skipped}, errors: [])
        end

        private

        def revert_keys(row)
          restore_work_keys(row)
          @book.identifiers.where(identifier_type: ApplyBook::DUPLICATE_KEY, value: row.duplicate_keys).destroy_all
          Array(row.author_changes["added"]).each do |author_id, key|
            ::Identifier.where(identifiable_type: "Books::Author", identifiable_id: author_id,
              identifier_type: :books_author_openlibrary_id, value: key).destroy_all
          end
        end

        # Undoes stages 2-4: identifiers the pass added go, sources it upgraded
        # go back. An identifier that moved to another book or is gone is
        # counted, not touched. Returns that count.
        def revert_findings(row, findings = row.findings)
          skipped = 0
          findings.added.each do |finding|
            identifier = held_identifier(finding)
            identifier ? identifier.destroy! : skipped += 1
          end
          findings.confirmed.each do |finding|
            identifier = held_identifier(finding)
            identifier ? identifier.update!(source: finding.previous_source) : skipped += 1
          end
          findings.delete_all
          skipped
        end

        def held_identifier(finding)
          ::Identifier.find_by(id: finding.identifier_id, identifiable_type: "Books::Book", identifiable_id: @book.id)
        end

        # Removes only the key the backfill gave; a work key that arrived later
        # (a merge, an admin) is not the backfill's to take away. Old keys were
        # legacy (the backfill only ever checked stored keys), so they come
        # back legacy, including one it confirmed and upgraded in place.
        def restore_work_keys(row)
          held = @book.identifiers.where(identifier_type: ApplyBook::WORK_KEY)
          held.where(value: row.new_key).destroy_all if row.new_key.present? && !row.old_keys.include?(row.new_key)
          held.where(value: row.old_keys).update_all(source: ::Identifier.sources[:legacy], updated_at: Time.current)
          (row.old_keys - held.reload.pluck(:value)).each do |key|
            @book.identifiers.create!(identifier_type: ApplyBook::WORK_KEY, value: key, source: :legacy)
          end
        end

        def failure(message) = Result.new(success?: false, data: nil, errors: [message])
      end
    end
  end
end
