# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # Merges a user-added provisional book into a catalog book that is the
      # same book (Services::Books::AdminMerge), which carries its list items, so
      # a reader's list ends up pointing at the real book.
      #
      # This never runs inside a transaction: the merger refuses to. So it is
      # check, merge, write:
      #   1. state, lease, input and target are judged on a fresh read;
      #   2. AdminMerge moves and closes every open row on the book as `merged`,
      #      attributed to the reviewer through Current;
      #   3. the note and sources are written on the rows that moved.
      #
      # Two limits follow from that, both accepted:
      # - The lease is checked before the merge and cannot be part of it. One
      #   that lapses during the merge still lets this merge finish; the next
      #   caller sees a closed row.
      # - If the process dies between 2 and 3, the book is already merged and the
      #   rows are already closed (`merged`, the acting user and via, a time,
      #   lease cleared) but carry no note or sources. Nothing needs undoing and
      #   nothing is re-run: the evidence the agent gave is lost, and a retry
      #   with the old token is a conflict because the row is closed.
      #
      # A dry run reports exactly what a real run would refuse, writes nothing
      # and takes no lock, so the lease is kept.
      class Merge
        Result = Lease::Result

        def self.call(submission:, target_id:, user:, via:, note:, lease_token: nil, sources: [], dry_run: false)
          new(submission: submission, target_id: target_id, user: user, via: via, lease_token: lease_token,
            note: note, sources: sources, dry_run: dry_run).call
        end

        def initialize(submission:, target_id:, user:, via:, lease_token:, note:, sources:, dry_run:)
          @submission = submission
          @target_id = target_id
          @user = user
          @via = Lease.via!(via)
          @token = lease_token
          @note = note
          @sources = sources
          @dry_run = dry_run
        end

        def call
          Lease.acting(@user, @via) { run }
        end

        private

        def run
          row = ::Books::BookSubmission.find_by(id: @submission.id)
          refusal = row.nil? ? Lease.failure(:conflict, "the submission no longer exists") : state_failure(row)
          refusal ||= Lease.lease_failure(row, @token, @via)
          refusal ||= Lease.input_failure(note: @note, sources: @sources, sources_required: @via == "api")
          return refusal if refusal

          source = row.book
          target = target_for(source)
          return target if target.is_a?(Result)
          return Lease.success(dry_run: true, source_id: source.id, target_id: target.id) if @dry_run

          merge(row, source, target)
        end

        def state_failure(row)
          return Lease.failure(:conflict, "the submission is #{row.review_status}, not awaiting review") unless Lease::OPEN_REVIEWS.include?(row.review_status)
          return Lease.failure(:conflict, "the submission has no book") if row.book.nil?
          return Lease.failure(:conflict, "the submission needs a human") if row.review_needs_human? && @via == "api"
          return Lease.failure(:conflict, "the book is no longer a provisional book") unless row.book.provisional?

          nil
        end

        # The target book, or a failed Result.
        def target_for(source)
          id = Integer(@target_id, exception: false) if @target_id.is_a?(Integer) || @target_id.is_a?(String)
          target = id && ::Books::Book.find_by(id: id)
          return Lease.failure(:invalid, "target_id names no book") unless target
          return Lease.failure(:invalid, "a book cannot be merged into itself") if target.id == source.id
          return Lease.failure(:invalid, "the target is a provisional book; merge into a catalog book") if target.provisional?

          target
        end

        def merge(row, source, target)
          # The rows the merger will close: read before the move, because
          # afterwards the target's own rows sit under the same book_id.
          moving = ::Books::BookSubmission.where(book_id: source.id, review_status: %w[pending needs_human not_needed]).pluck(:id)
          result = ::Services::Books::AdminMerge.call(source: source, target: target)
          return merge_failure(row, result) unless result.success?

          ::Books::BookSubmission.where(id: moving, review_status: :merged)
            .update_all(review_note: @note, review_sources: @sources || [], updated_at: Time.current)
          Lease.success(submission: ::Books::BookSubmission.find(row.id), target: target, warnings: result.data[:warnings])
        end

        # A merge that fails because the row was settled meanwhile (another
        # reviewer's approve took the book) is a conflict; any other is the
        # merger's own refusal.
        def merge_failure(row, result)
          fresh = ::Books::BookSubmission.find_by(id: row.id)
          return Lease.failure(:conflict, "the submission was settled while it was being merged") unless fresh && Lease::OPEN_REVIEWS.include?(fresh.review_status) && fresh.book_id == row.book_id

          Lease.failure(:invalid, Array(result.errors).join("; "))
        end
      end
    end
  end
end
