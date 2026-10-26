# frozen_string_literal: true

module Services
  module Books
    # Writes identifier pairs onto a BOOK under one collision rule, shared by
    # every provider that attaches identifiers (Amazon, Goodreads). Every other
    # identifier on a book is trusted by the duplicate-reduction work, so one
    # wrong value is worse than a missing one: when another book already holds
    # any of these values from a verified source (Open Library, WorldCat),
    # NOTHING is written and the pair is flagged for a human instead. A value
    # held by another book from an unverified source does not block the write,
    # because that holder is as likely to be the wrong one.
    class BookIdentifierWriter
      Result = Struct.new(:written, :flagged_book_ids, keyword_init: true)

      # pairs: [[identifier_type_string, value], ...]. evidence is the provider's
      # own context; the conflicts are merged in under "conflicts".
      def self.call(book:, pairs:, source:, evidence: {})
        new(book: book, pairs: pairs, source: source, evidence: evidence).call
      end

      def initialize(book:, pairs:, source:, evidence: {})
        @book = book
        @pairs = pairs
        @source = source
        @evidence = evidence
      end

      def call
        conflicts = verified_conflicts
        return flag(conflicts) if conflicts.any?

        written = []
        ::Identifier.transaction do
          @pairs.each do |type, value|
            row = @book.identifiers.find_or_initialize_by(identifier_type: type, value: value)
            row.source = @source if row.new_record?
            row.save!
            written << [type, value]
          end
        end
        Result.new(written: written, flagged_book_ids: [])
      end

      private

      # One publication can sit on another book under a different form: the
      # same ISBN as 10 or 13 digits, and a physical book's ASIN is usually its
      # ISBN-10. Each value is checked in every form, and a conflict is reported
      # against the value as the provider gave it.
      def verified_conflicts
        @pairs.flat_map do |type, value|
          equivalents(type, value).flat_map do |held_type, held_value|
            ::Identifier.where(identifiable_type: "Books::Book", identifier_type: held_type, value: held_value)
              .where.not(identifiable_id: @book.id).verified
              .map { |row| {"identifier_type" => type, "value" => value, "holder_book_id" => row.identifiable_id, "holder_source" => row.source} }
          end
        end.uniq
      end

      def equivalents(type, value)
        forms = [[type, value]]
        normalized = ::Books::Isbn.normalize(value)
        return forms if normalized.nil?

        forms << ["books_work_isbn13", normalized.isbn13]
        forms << ["books_work_isbn10", normalized.isbn10] if normalized.isbn10
        forms.uniq
      end

      def flag(conflicts)
        by_holder = conflicts.group_by { |conflict| conflict["holder_book_id"] }
        by_holder.each do |holder_id, holder_conflicts|
          ::Services::DuplicateCandidates::Flag.call(
            item_type: "Books::Book",
            ids: [@book.id, holder_id],
            source: :identifier_collision,
            evidence: @evidence.merge("conflicts" => holder_conflicts),
            match_decision: nil
          )
        end
        Result.new(written: [], flagged_book_ids: by_holder.keys)
      end
    end
  end
end
