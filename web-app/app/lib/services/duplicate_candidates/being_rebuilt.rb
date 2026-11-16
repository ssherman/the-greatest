# frozen_string_literal: true

module Services
  module DuplicateCandidates
    # Records a running repair is about to empty and delete, whose duplicate pairs cannot be judged yet. Today that is
    # the Goodreads re-import's mixed books: one legacy record holding readers of several different books, with an
    # approved reimport_mixed verdict that empties and deletes it once its readers have moved. "Is it the same as X?"
    # has no single answer for such a record, so its pairs are kept out of the queue (the admin page, the admin API and
    # so the MCP list) and closed when the record is deleted. A mixed book the re-import keeps (some readers belong on
    # it) stops being one, and its pairs come back.
    module BeingRebuilt
      module_function

      CLOSED_NOTE = "Record emptied and deleted by the Goodreads re-import: it held readers of several different books " \
        "(a mixed book), so it was never a duplicate of one."

      # The ids of the books whose mixed verdict is approved, current, not yet applied and not kept.
      def book_ids_relation
        ::Books::RepairVerdict.reimport_mixed.approved.current.where(applied_at: nil)
          .where("(payload->>'kept') IS DISTINCT FROM 'true'")
          .select(Arel.sql("(payload->>'book_id')::bigint"))
      end

      def condition
        ids = book_ids_relation.to_sql
        "duplicate_candidates.item_type = 'Books::Book' AND " \
          "(duplicate_candidates.item_a_id IN (#{ids}) OR duplicate_candidates.item_b_id IN (#{ids}))"
      end

      def exclude(scope) = scope.where.not(Arel.sql(condition))

      def only(scope) = scope.where(Arel.sql(condition))

      # Which of these book ids are being rebuilt.
      def book_ids(ids)
        return Set.new if ids.empty?

        book_ids_relation.where("(payload->>'book_id')::bigint IN (?)", ids).pluck(Arel.sql("(payload->>'book_id')::bigint")).to_set
      end

      # The deleted book's pending pairs are answered: it was not a duplicate of any one book. Returns how many closed.
      def close_pairs_for(book_id)
        ::DuplicateCandidate.pending.where(item_type: "Books::Book").where("item_a_id = :id OR item_b_id = :id", id: book_id)
          .update_all(status: ::DuplicateCandidate.statuses[:not_duplicate], resolved_at: Time.current,
            resolution_note: CLOSED_NOTE, updated_at: Time.current)
      end
    end
  end
end
