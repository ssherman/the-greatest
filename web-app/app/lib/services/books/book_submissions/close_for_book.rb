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
      # The lease is cleared so a closed row can never be held by an agent. The
      # agent queue also excludes it by review_status (`reviewable`), including a
      # failed or needs_details row.
      #
      # A rejection is terminal for a row still in progress: in the same UPDATE a
      # queued or looking_up row becomes cancelled, so a job that resumes after
      # the book was deleted finds nothing to do instead of making a second book.
      # The reader's strip still shows a cancelled row whose review is rejected.
      # A row its reader had dismissed ("Added X") is shown again: the book is
      # gone from their list, and they must be told once. Dismissing it again
      # hides it for good, because a rejected row never closes again.
      # A note is written only when given, so a needs_human row keeps its own.
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
          statuses = ::Books::BookSubmission.statuses
          changes = {
            review_status: ::Books::BookSubmission.review_statuses.fetch(review_status.to_s),
            reviewed_via: vias.fetch(via.to_s) { vias.fetch("system") },
            reviewed_by_id: user&.id,
            reviewed_at: now,
            lease_token: nil,
            lease_expires_at: nil,
            updated_at: now
          }
          changes[:review_note] = note unless note.nil?
          if review_status.to_s == "rejected"
            open = ::Books::BookSubmission::IN_PROGRESS_STATUSES.map { |name| statuses.fetch(name) }.join(", ")
            changes[:status] = Arel.sql("CASE WHEN status IN (#{open}) THEN #{statuses.fetch("cancelled")} ELSE status END")
            changes[:dismissed_at] = nil
          end
          scope.update_all(changes)
        end
      end
    end
  end
end
