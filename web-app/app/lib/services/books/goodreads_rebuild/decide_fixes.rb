# frozen_string_literal: true

module Services
  module Books
    module GoodreadsRebuild
      # Picks the derived books that need a fix and queues them for DecideFixJob in
      # batches. The books listed by the most members go first, so a stop part way
      # leaves the least important ones undone.
      module DecideFixes
        module_function

        BATCH_SIZE = 100

        # The SQL form of DecideFix.needs_fix?; a test keeps the two equal. Null
        # means "not known to agree", which is why each test is IS TRUE.
        NEEDS_FIX_SQL = <<~SQL.squish
          books_rebuild_book_surveys.classification IN (:judged)
          AND NOT (books_rebuild_book_surveys.title_agrees IS TRUE
            AND books_rebuild_book_surveys.authors_agree IS TRUE
            AND books_rebuild_book_surveys.wrong_book IS NOT TRUE)
        SQL

        def candidates
          counts = ::UserListItem.where(listable_type: "Books::Book").group(:listable_id).select("listable_id, COUNT(*) AS item_count")
          judged = ::Books::RebuildBookSurvey.classifications.values_at("coherent", "lump")
          Cohort.derived
            .joins("INNER JOIN books_rebuild_book_surveys ON books_rebuild_book_surveys.book_id = books_books.id")
            .joins("LEFT JOIN (#{counts.to_sql}) list_counts ON list_counts.listable_id = books_books.id")
            .where(NEEDS_FIX_SQL, judged: judged)
            .reorder(Arel.sql("COALESCE(list_counts.item_count, 0) DESC, books_books.id"))
        end

        def enqueue(limit:)
          ids = candidates.pluck(:id)
          ids = ids.first(limit) if limit
          ids.each_slice(BATCH_SIZE) { |batch| ::Books::GoodreadsRebuild::DecideFixesJob.perform_async(batch) }
          ids.size
        end
      end
    end
  end
end
