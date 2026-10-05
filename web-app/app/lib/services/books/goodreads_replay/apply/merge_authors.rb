# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      module Apply
        # Applies a merge_authors verdict through Books::Author::Merger, which
        # moves everything and reindexes. The author ranking recalculation is
        # deferred to ApplyVerdicts, once per run. An author already merged away (or
        # deleted) is a no-op: the next pass re-derives the pair from what is
        # left.
        class MergeAuthors
          Result = Struct.new(:success?, :data, :errors, keyword_init: true)

          def self.call(verdict:)
            source = ::Books::Author.find_by(id: verdict.payload["source_id"])
            return noop("author #{verdict.payload["source_id"]} no longer exists") unless source

            target = ::Books::Author.find_by(id: verdict.payload["target_id"])
            return noop("author #{verdict.payload["target_id"]} no longer exists") unless target

            result = ::Books::Author::Merger.call(source: source, target: target, defer_rankings: true)
            raise Failed, result.errors.join("; ") unless result.success?

            Result.new(success?: true, data: {outcome: :applied, follow_ups: [:author_rankings]}, errors: [])
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
