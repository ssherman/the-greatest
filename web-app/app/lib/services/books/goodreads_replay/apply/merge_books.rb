# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      module Apply
        # Applies a merge_books verdict through Books::Book::Merger, which moves
        # list items, reviews, identifiers and editions, then reindexes. Its
        # ranking recalculations and the favorites rebuild are deferred: the
        # result names them, and ApplyVerdicts queues each once per run, not once
        # per merge. Either book already gone is a no-op.
        class MergeBooks
          Result = Struct.new(:success?, :data, :errors, keyword_init: true)

          def self.call(verdict:)
            source = ::Books::Book.find_by(id: verdict.payload["source_id"])
            return noop("book #{verdict.payload["source_id"]} no longer exists") unless source

            target = ::Books::Book.find_by(id: verdict.payload["target_id"])
            return noop("book #{verdict.payload["target_id"]} no longer exists") unless target

            reset_source(verdict, source) if verdict.payload["reset_source"]

            merger = ::Books::Book::Merger.new(source: source, target: target, defer_rankings: true)
            result = merger.call
            raise Failed, result.errors.join("; ") unless result.success?

            data = {outcome: :applied, reweigh_configuration_ids: merger.affected_ranking_configurations, follow_ups: [:user_favorites]}
            Result.new(success?: true, data: data, errors: [])
          end

          # A rebuild merge (reset_source): the source is a derived book whose
          # legacy data is a guess, so it is cleared before its users' data moves
          # to the target. Its archive goes on the verdict in the same transaction as the
          # reset, only the first time: a retry's reset finds nothing left to archive.
          def self.reset_source(verdict, source)
            raise Failed, "source is trusted now" if GoodreadsRebuild::Cohort.trusted?(source.id)

            ::Books::Book.transaction do
              archive = GoodreadsRebuild::ResetBook.call(book: source).data[:removed]
              verdict.update_columns(payload: verdict.payload.merge("removed" => archive)) unless verdict.payload.key?("removed")
            end
          end

          def self.noop(reason)
            Result.new(success?: true, data: {outcome: :noop, reason: reason}, errors: [])
          end

          private_class_method :reset_source, :noop
        end
      end
    end
  end
end
