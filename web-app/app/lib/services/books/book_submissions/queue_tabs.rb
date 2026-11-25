# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # The admin page's tabs and the prompt's counts: one definition of which
      # rows are waiting for what. "Needs review" and "needs details" are the
      # agent queue (`reviewable`) split by whether a book exists, as the
      # claim and the API's `needs` split it.
      module QueueTabs
        TABS = {
          "needs_review" => -> { ::Books::BookSubmission.reviewable.where.not(book_id: nil) },
          "needs_details" => -> { ::Books::BookSubmission.reviewable.where(book_id: nil) },
          "needs_human" => -> { ::Books::BookSubmission.review_needs_human },
          "approved" => -> { ::Books::BookSubmission.review_approved },
          "merged" => -> { ::Books::BookSubmission.review_merged },
          "rejected" => -> { ::Books::BookSubmission.review_rejected },
          "failed" => -> { ::Books::BookSubmission.failed },
          "all" => -> { ::Books::BookSubmission.all }
        }.freeze
        KEYS = TABS.keys.freeze
        DEFAULT = "needs_review"

        module_function

        # The tab asked for if it is one of ours; the default otherwise.
        def valid(tab) = KEYS.include?(tab) ? tab : DEFAULT

        def scope(tab) = TABS.fetch(valid(tab)).call

        # {tab => count}, every tab in one query.
        def counts
          selects = TABS.map { |tab, scope| "(#{scope.call.unscope(:order).select("COUNT(*)").to_sql}) AS #{tab}" }
          row = ::Books::BookSubmission.connection.select_one("SELECT #{selects.join(", ")}")
          KEYS.to_h { |tab| [tab, row.fetch(tab).to_i] }
        end
      end
    end
  end
end
