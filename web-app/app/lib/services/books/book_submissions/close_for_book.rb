# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # Closes the open submissions of books that were promoted, merged or deleted
      # by a route that knows nothing about submissions (the Goodreads import
      # approval, the book merger, the book's destroy). One UPDATE, so a book
      # with no submissions costs one query and the hook can sit on every destroy.
      #
      # Only pending and needs_human rows close. A row already approved, merged or
      # rejected is left as it was, which is also how an approve that stamped its
      # own row first stays untouched. include_matched also takes not_needed rows,
      # another reader's submission that resolved to the same provisional book and
      # so shares its fate; callers pass it only when the book was provisional,
      # because a not_needed row on a catalog book is just a reader who found it.
      #
      # The lease is cleared so a closed row can never be held by an agent.
      # claimable already excludes it (it reads review_status), the lease would
      # only be stale data.
      #
      # submission_ids narrows the close to rows the caller captured earlier: the
      # merger moves rows onto the survivor, where the survivor's own rows and the
      # moved ones could no longer be told apart by book.
      class CloseForBook
        CLOSABLE = %w[pending needs_human].freeze

        def self.call(book_ids:, review_status:, user: Current.acting_user, via: Current.acting_via || "system",
          note: nil, include_matched: false, submission_ids: nil)
          statuses = include_matched ? CLOSABLE + %w[not_needed] : CLOSABLE
          scope = ::Books::BookSubmission.where(book_id: book_ids, review_status: statuses)
          scope = scope.where(id: submission_ids) unless submission_ids.nil?
          now = Time.current
          # "via" pluralises to itself, so the enum's mapping is reviewed_via, not reviewed_vias.
          vias = ::Books::BookSubmission.reviewed_via
          scope.update_all(
            review_status: ::Books::BookSubmission.review_statuses.fetch(review_status.to_s),
            reviewed_via: vias.fetch(via.to_s) { vias.fetch("system") },
            reviewed_by_id: user&.id,
            reviewed_at: now,
            review_note: note,
            lease_token: nil,
            lease_expires_at: nil,
            updated_at: now
          )
        end
      end
    end
  end
end
