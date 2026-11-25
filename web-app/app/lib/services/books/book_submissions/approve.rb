# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # An admin or an agent decides a user-added book is real: the book and its
      # provisional authors join the catalog (GoodreadsImports::PromoteRecords,
      # in the priority lane) and every submission on the book closes approved.
      #
      # One transaction: the reader locks (DestructionInvalidator, as the
      # promotion itself takes them), then the book row FOR UPDATE, then this
      # row's stamp, then the promotion. That is the order of Reject. A lookup
      # job's list add takes its reader FOR NO KEY UPDATE and then the book FOR
      # KEY SHARE, so a decision that took the book first and a reader second
      # could wait for a job that is waiting for the book.
      # The acting admin may be the reader (the agent's token and the site
      # owner's account are one user), which the stamp's foreign key tolerates
      # because it only needs KEY SHARE on that user.
      #
      # The stamp is one conditional UPDATE on the row still being open and the
      # lease still live, so two callers cannot both approve. This row carries
      # the note and sources; the other readers' rows are closed by the
      # promotion, approved, with the same reviewer and no note.
      class Approve
        Result = Lease::Result

        def self.call(submission:, user:, via:, note:, lease_token: nil, sources: [])
          new(submission: submission, user: user, via: via, lease_token: lease_token, note: note, sources: sources).call
        end

        def initialize(submission:, user:, via:, lease_token:, note:, sources:)
          @submission = submission
          @user = user
          @via = Lease.via!(via)
          @token = lease_token
          @note = note
          @sources = sources
        end

        # Whether the admin page may offer this row an approval: still open, and a book that is
        # still provisional (the service refuses a public one). Read from a loaded row.
        def self.available?(row) = row.book_id.present? && Lease::OPEN_REVIEWS.include?(row.review_status) && row.book&.provisional? == true

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

          approve(row)
        end

        def state_failure(row)
          return Lease.failure(:conflict, "the submission is #{row.review_status}, not awaiting review") unless open?(row)
          return Lease.failure(:conflict, "the submission has no book") if row.book_id.nil?
          # needs_human is the admin page's: a lease never covers it, so the API cannot hold one.
          return Lease.failure(:conflict, "the submission needs a human") if row.review_needs_human? && @via == "api"

          nil
        end

        def open?(row) = Lease::OPEN_REVIEWS.include?(row.review_status)

        def approve(row)
          refusal = nil
          book = nil
          ActiveRecord::Base.transaction do
            lock_readers(row.book_id)
            book = lock_book(row.book_id)
            refusal = Lease.failure(:conflict, "the book is no longer a provisional book") unless book&.provisional?
            refusal ||= stamp(row, book)
            raise ActiveRecord::Rollback if refusal

            ::Services::Books::GoodreadsImports::PromoteRecords.call(books: [book], authors: [], initiated_by: "book_submission", lane: "priority")
            resume(row)
          end
          refusal || Lease.success(submission: ::Books::BookSubmission.find(row.id), book: book)
        end

        # A row that failed after it got its book never put the book on the
        # reader's list. Approving it resumes it: counters reset, status queued,
        # and the job (which resumes at the list step) queued after the commit.
        # Its review state is the approval just stamped.
        def resume(row)
          return unless Requeue.reset(::Books::BookSubmission.where(status: :failed), id: row.id).positive?

          ActiveRecord.after_all_transactions_commit { Requeue.enqueue(row.id) }
        end

        def lock_readers(book_id)
          book = ::Books::Book.find_by(id: book_id)
          ::Services::Books::ReadingGoals::DestructionInvalidator.for_book(book: book) if book
        end

        # FOR UPDATE: the promotion rewrites the book, and a list add (FOR KEY
        # SHARE) must wait for it and then see the book public.
        def lock_book(id) = ::Books::Book.lock.find_by(id: id)

        def stamp(row, book)
          scope = ::Books::BookSubmission.where(id: row.id, book_id: book.id, review_status: Lease::OPEN_REVIEWS)
          scope = scope.where.not(review_status: :needs_human) if @via == "api"
          changed = Lease.guard(scope, @token, @via)
            .update_all(Lease.closing(:approved, user: @user, via: @via, note: @note, sources: @sources || []))
          Lease.failure(:conflict, "the submission changed while it was being approved") if changed.zero?
        end
      end
    end
  end
end
