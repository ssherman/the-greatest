# frozen_string_literal: true

module Services
  module Books
    module GoodreadsReplay
      module Apply
        # Applies (or, from the admin queue, reverts) a mark_provisional verdict.
        # Uses update!, never update_all, so SearchIndexable's after_commit
        # queues the reindex and public search drops the book. Rankings filter
        # provisional books when they are calculated, so the result names the
        # configurations to recalculate: those that ranked the book, plus the
        # default one, whose job cascades to the author rankings. ApplyVerdicts
        # queues each configuration once per run.
        class MarkProvisional
          Result = Struct.new(:success?, :data, :errors, keyword_init: true)

          def self.call(verdict:)
            set(verdict, true)
          end

          def self.revert(verdict:)
            set(verdict, false)
          end

          def self.set(verdict, provisional)
            book = ::Books::Book.find_by(id: verdict.payload["book_id"])
            return noop("book #{verdict.payload["book_id"]} no longer exists") unless book
            return noop(provisional ? "already provisional" : "not provisional") if book.provisional == provisional

            configurations = ranking_configuration_ids(book)
            book.update!(provisional: provisional)
            Result.new(success?: true, data: {outcome: :applied, ranking_configuration_ids: configurations}, errors: [])
          end

          def self.ranking_configuration_ids(book)
            ranked = ::RankedItem.where(item_type: "Books::Book", item_id: book.id).distinct.pluck(:ranking_configuration_id)
            (ranked + [::Books::RankingConfiguration.default_primary&.id]).compact.uniq
          end

          def self.noop(reason)
            Result.new(success?: true, data: {outcome: :noop, reason: reason}, errors: [])
          end

          private_class_method :set, :ranking_configuration_ids, :noop
        end
      end
    end
  end
end
