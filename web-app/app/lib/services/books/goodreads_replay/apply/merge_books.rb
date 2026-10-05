# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      module Apply
        # Applies a merge_books verdict through Books::Book::Merger, which moves
        # list items, reviews, identifiers and editions, then reindexes and
        # recalculates rankings. Either book already gone is a no-op.
        class MergeBooks
          Result = Struct.new(:success?, :data, :errors, keyword_init: true)

          def self.call(verdict:)
            source = ::Books::Book.find_by(id: verdict.payload["source_id"])
            return noop("book #{verdict.payload["source_id"]} no longer exists") unless source

            target = ::Books::Book.find_by(id: verdict.payload["target_id"])
            return noop("book #{verdict.payload["target_id"]} no longer exists") unless target

            result = ::Books::Book::Merger.call(source: source, target: target)
            raise Failed, result.errors.join("; ") unless result.success?

            Result.new(success?: true, data: {outcome: :applied}, errors: [])
          end

          def self.noop(reason)
            Result.new(success?: true, data: {outcome: :noop, reason: reason}, errors: [])
          end

          private_class_method :noop
        end
      end
    end
  end
end
