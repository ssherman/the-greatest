# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # Deletes a user-added provisional book that is not real, with the items
      # and reviews of the readers who asked for it, and closes every submission
      # on it rejected (a row still in progress is cancelled with it).
      #
      # Refused (:invalid, naming the uses, BookUses) when anyone who did not
      # submit the book uses it, when no submission created it, and (:conflict)
      # when it is no longer provisional.
      #
      # One transaction, locks in this order, which is the order of Approve and
      # the opposite of what would deadlock with a lookup job's list add (reader
      # FOR NO KEY UPDATE, then the book FOR KEY SHARE):
      #   1. DestructionInvalidator.for_book: locks every reader who has the book
      #      on Read, and returns the goal pages to purge after the commit;
      #   2. the book row FOR UPDATE;
      #   3. the checks again, under the lock (state, lease, BookUses);
      #   4. every open row on the book is closed with the note and sources,
      #      then the book is destroyed (the destroy hook finds nothing left to
      #      close), then the provisional authors left with nothing are.
      # A reader who adds the book to a list between the BookUses check and the
      # destroy has that item destroyed with the book, as a submitter's would be;
      # nothing but a submission's own create path makes a book reachable, and
      # that ends in the close above.
      #
      # An author is destroyed only when nothing could still point at it: no
      # book_authors, no credit on a record that survives (credits on this book and its
      # editions go with it, so they are no reason: the preview and the real run
      # agree on that), no author
      # relationship, no import record, and no merge redirect to it. When in
      # doubt it stays; the admin author delete is the way to remove one.
      #
      # A dry run reports what a real run would refuse or do. It writes nothing,
      # takes no lock and keeps the lease.
      class Reject
        Result = Lease::Result

        def self.call(submission:, user:, via:, note:, lease_token: nil, sources: [], dry_run: false)
          new(submission: submission, user: user, via: via, lease_token: lease_token, note: note, sources: sources, dry_run: dry_run).call
        end

        def initialize(submission:, user:, via:, lease_token:, note:, sources:, dry_run:)
          @submission = submission
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
          refusal ||= book_failure(row.book)
          return refusal if refusal

          @dry_run ? preview(row.book) : reject(row)
        end

        def state_failure(row)
          return Lease.failure(:conflict, "the submission is #{row.review_status}, not awaiting review") unless Lease::OPEN_REVIEWS.include?(row.review_status)
          return Lease.failure(:conflict, "the submission has no book") if row.book.nil?
          return Lease.failure(:conflict, "the submission needs a human") if row.review_needs_human? && @via == "api"

          nil
        end

        # Provisional and created by a submission, and not used by anyone else.
        def book_failure(book)
          return Lease.failure(:conflict, "the book is no longer a provisional book") unless book.provisional?
          unless ::Books::BookSubmission.where(book_id: book.id, created_book: true).exists?
            return Lease.failure(:invalid, "no submission created this book, so it is not a user-added book")
          end

          uses = BookUses.call(book: book)
          Lease.failure(:invalid, "the book is in use: #{uses.join("; ")}") if uses.any?
        end

        def preview(book)
          Lease.success(dry_run: true, book_id: book.id, author_ids: orphan_candidates(book).map(&:id),
            submission_ids: open_row_ids(book))
        end

        def reject(row)
          refusal = nil
          urls = []
          author_ids = []
          book_id = row.book_id
          ActiveRecord::Base.transaction do
            book = ::Books::Book.find_by(id: book_id)
            urls = ::Services::Books::ReadingGoals::DestructionInvalidator.for_book(book: book) if book
            book = lock_book(book_id)
            refusal = locked_failure(row, book)
            raise ActiveRecord::Rollback if refusal

            candidates = book.authors.where(provisional: true).order(:id).to_a
            close(book)
            book.destroy!
            author_ids = candidates.select { destroy_if_orphaned(it) }.map(&:id)
          end
          return refusal if refusal

          if urls.any?
            ActiveRecord.after_all_transactions_commit { ::Books::ReadingGoals::PurgeCachedPagesJob.perform_async("books", urls) }
          end
          Lease.success(book_id: book_id, author_ids: author_ids, submission: ::Books::BookSubmission.find(row.id))
        end

        # FOR UPDATE, after the readers: see the class comment.
        def lock_book(id) = ::Books::Book.lock.find_by(id: id)

        # The checks again, now that nothing can change under them.
        def locked_failure(row, book)
          return Lease.failure(:conflict, "the book no longer exists") unless book

          fresh = ::Books::BookSubmission.lock.find_by(id: row.id)
          return Lease.failure(:conflict, "the submission changed while it was being rejected") if fresh.nil? || fresh.book_id != book.id

          state_failure(fresh) || Lease.lease_failure(fresh, @token, @via) || book_failure(book)
        end

        def open_row_ids(book)
          ::Books::BookSubmission.where(book_id: book.id, review_status: %w[pending needs_human not_needed]).pluck(:id)
        end

        # Every open row on the book, the matched readers' too, so each carries
        # why. The destroy hook then has nothing left to close.
        def close(book)
          ids = open_row_ids(book)
          CloseForBook.call(book_ids: [book.id], review_status: :rejected, user: @user, via: @via, note: @note,
            include_matched: true, submission_ids: ids)
          ::Books::BookSubmission.where(id: ids).update_all(review_sources: @sources || [], updated_at: Time.current)
        end

        # The authors a real run would destroy, as the preview says them. A
        # credit on this book or on one of its editions (an illustrator, a
        # translator) goes with the book (dependent: :destroy), so it is no
        # reason to keep the author: the real run decides after the destroy and
        # so ignores such credits, and the preview ignores them too, so the two
        # agree. A credit on any other record keeps the author in both.
        def orphan_candidates(book)
          book.authors.where(provisional: true).order(:id).select { orphan?(it, going: book) }
        end

        def orphan?(author, going: nil)
          credited = ::Books::BookAuthor.where(author_id: author.id)
          credited = credited.where.not(book_id: going.id) if going
          !credited.exists? && !kept_for_other_reasons?(author, going)
        end

        def kept_for_other_reasons?(author, going)
          credits(author, going).exists? ||
            ::Books::AuthorRelationship.where(from_author_id: author.id).or(::Books::AuthorRelationship.where(to_author_id: author.id)).exists? ||
            ::Books::GoodreadsImportRecord.where(record: author).exists? ||
            RecordRedirect.where(item_type: "Books::Author", to_id: author.id).exists?
        end

        def credits(author, going)
          credits = ::Books::Credit.where(author_id: author.id)
          return credits unless going

          going_to_destroy = ::Books::Credit.where(creditable_type: "Books::Book", creditable_id: going.id)
            .or(::Books::Credit.where(creditable_type: "Books::Edition", creditable_id: ::Books::Edition.where(book_id: going.id).select(:id)))
          credits.where.not(id: going_to_destroy.select(:id))
        end

        # Locked and re-read, so a book credited since the check is kept.
        def destroy_if_orphaned(author)
          locked = ::Books::Author.lock.find_by(id: author.id)
          return false unless locked&.provisional? && orphan?(locked)

          locked.destroy!
          true
        end
      end
    end
  end
end
