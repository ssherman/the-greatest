# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      module Apply
        # Applies a strip_identifier verdict: removes the payload's identifiers
        # from the book and adds the ones it lacks (spec §12.2, §12.4). Relink
        # uses .change to move a wrong row's identifiers from one book to
        # another. An added identifier another book already holds flags the two
        # as a suspected duplicate pair, as the finder does for a collision.
        # Idempotent: what is already gone, or already there, is left alone.
        #
        # A verdict that both removes and adds is a replacement (a slug for its
        # bare id): when nothing it names is left to remove, the identifier was
        # already replaced or moved elsewhere (a relink took it to the right
        # book), so nothing is added either.
        class StripIdentifier
          Result = Struct.new(:success?, :data, :errors, keyword_init: true)

          def self.call(verdict:)
            book = ::Books::Book.find_by(id: verdict.payload["book_id"])
            return noop("book #{verdict.payload["book_id"]} no longer exists") unless book

            remove = Array(verdict.payload["remove"])
            add = Array(verdict.payload["add"])
            if remove.any? && add.any? && remove.none? { |type, value| book.identifiers.exists?(identifier_type: type, value: value) }
              return noop("nothing left to replace")
            end

            changed = change(book: book, remove: remove, add: add)
            changed.zero? ? noop("already applied") : Result.new(success?: true, data: {outcome: :applied}, errors: [])
          end

          def self.change(book:, remove:, add:)
            changed = 0
            ActiveRecord::Base.transaction do
              Array(remove).each do |type, value|
                changed += book.identifiers.where(identifier_type: type, value: value).destroy_all.size
              end
              Array(add).each do |type, value|
                next if book.identifiers.exists?(identifier_type: type, value: value)

                ::Identifier.create!(identifiable: book, identifier_type: type, value: value)
                changed += 1
              end
            end
            Array(add).each { |type, value| flag_collisions(book, type, value) }
            changed
          end

          def self.flag_collisions(book, type, value)
            ::Identifier.where(identifiable_type: "Books::Book", identifier_type: type, value: value)
              .where.not(identifiable_id: book.id).pluck(:identifiable_id).each do |other_id|
              ::Services::DuplicateCandidates::Flag.call(
                item_type: "Books::Book", ids: [book.id, other_id], source: :identifier_collision,
                evidence: {reason: "both hold #{type} #{value} after a Goodreads replay identifier fix"}
              )
            end
          end

          def self.noop(reason)
            Result.new(success?: true, data: {outcome: :noop, reason: reason}, errors: [])
          end

          private_class_method :flag_collisions, :noop
        end
      end
    end
  end
end
