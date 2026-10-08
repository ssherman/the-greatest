# frozen_string_literal: true

module Services
  module Books
    module OlBackfill
      # Spec section 4, books:ol_backfill_revert: put a book's keys back the
      # way they were before the backfill. The row becomes `reverted`, which
      # no later run takes again.
      class Revert
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        REVERTIBLE = ::Books::OpenLibraryBackfill::KEYED_OUTCOMES

        def self.call(book:)
          new(book).call
        end

        def initialize(book)
          @book = book
        end

        def call
          row = ::Books::OpenLibraryBackfill.find_by(book: @book)
          return failure("book #{@book.id} has no backfill row") unless row
          unless REVERTIBLE.include?(row.outcome)
            return failure("book #{@book.id} is #{row.outcome}; only #{REVERTIBLE.join(", ")} can be reverted")
          end

          ::ActiveRecord::Base.transaction do
            restore_work_keys(row.old_keys)
            @book.identifiers.where(identifier_type: ApplyBook::DUPLICATE_KEY, value: row.duplicate_keys).destroy_all
            Array(row.author_changes["added"]).each do |author_id, key|
              ::Identifier.where(identifiable_type: "Books::Author", identifiable_id: author_id,
                identifier_type: :books_author_openlibrary_id, value: key).destroy_all
            end
            row.update!(outcome: :reverted)
          end
          Result.new(success?: true, data: row, errors: [])
        end

        private

        def restore_work_keys(old_keys)
          held = @book.identifiers.where(identifier_type: ApplyBook::WORK_KEY)
          held.where.not(value: old_keys).destroy_all
          (old_keys - held.reload.pluck(:value)).each do |key|
            @book.identifiers.create!(identifier_type: ApplyBook::WORK_KEY, value: key)
          end
        end

        def failure(message) = Result.new(success?: false, data: nil, errors: [message])
      end
    end
  end
end
