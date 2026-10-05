# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      # Goodreads import spec §12.2. The legacy app stored 543 Goodreads ids as
      # slugs or URLs (32076670-ball-lightning) and they were migrated as they
      # were, so no identifier lookup of the bare id finds them. Each one
      # becomes a rule-certain strip_identifier verdict that swaps it for the
      # bare id. Applying the verdict (Apply::StripIdentifier) also removes the
      # duplicate that leaves when the book already holds the bare id. Records
      # findings only; changes nothing.
      class FixSlugIdentifiers
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        TYPE = "books_work_goodreads_id"

        def self.call
          new.call
        end

        def call
          recorded = 0
          slugs.find_each do |identifier|
            bare = identifier.value[/\A\d+/]
            next if bare.nil?

            RecordVerdict.call(
              kind: :strip_identifier, subject_key: "book:#{identifier.identifiable_id}:#{TYPE}:#{identifier.value}",
              payload: {book_id: identifier.identifiable_id, remove: [[TYPE, identifier.value]], add: [[TYPE, bare]]},
              decided_by: :rule, confidence: :certain, reason: "slug-form Goodreads id #{identifier.value} is #{bare}", auto: true
            )
            recorded += 1
          end
          Result.new(success?: true, data: {recorded: recorded}, errors: [])
        end

        private

        def slugs
          ::Identifier.where(identifiable_type: "Books::Book", identifier_type: TYPE).where("value !~ '^[0-9]+$'")
        end
      end
    end
  end
end
