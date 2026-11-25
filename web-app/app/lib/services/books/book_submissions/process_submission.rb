# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # Takes one reader's submission from its input to a book on their list.
      # Runs in ProcessBookSubmissionJob, never in a web request. (Not named
      # Process: that would shadow Ruby's ::Process in this namespace.)
      #
      # data[:outcome] is :done (settled, or nothing left to do), :retry
      # (data[:retry_at]: the job runs it again then) or
      # :waiting_for_goodreads (the job queues the fetch).
      #
      # The steps, in the order a crash can resume from:
      #   1. The book: ResolveInput's facts, the finder (with every identifier
      #      source but legacy), and CreateBook, which writes book, created_book,
      #      match_decision and review_status and leaves status looking_up.
      #   2. The list. "Item already in list" is success and its item is found.
      #   3. The lookups, for a book this submission created.
      #   4. status added, with the list item.
      # A submission that already has its book skips straight to step 2, so a
      # crash never loses the list item and never makes a second book. Once
      # the book exists a deleted list just means no item; the submission is
      # still added. Before it exists, a missing user or list means cancelled.
      #
      # Retries are for a source that is down (see RetrySchedule): the
      # resolve step unavailable, or an unmatched finder answer that fell back
      # (its AI failed), had a local source fail, or had Open Library fail.
      # When the window has passed the resolve step's unavailability is
      # needs_details, a fallback or a failed local source is failed, and
      # Open Library alone goes on to create. A match is used at once whatever
      # its confidence and whatever failed: the finder always decides, and the
      # decision's own review flag audits it.
      #
      # Every write that ends or reschedules a submission without a book goes
      # through Settle, so a cancel or a finished row is never overwritten.
      #
      # Review queue. Whatever way a run ends, every flagged decision about this
      # submission other than the one the submission now holds is taken out of
      # the review queue (this run's unused one, a crashed run's, a second job's
      # that lost the race), as GoodreadsImports::ResolveEdition does. When the
      # run raises (except a Postgres error, whose connection cannot be trusted)
      # the same happens before it re-raises, and the job's final failure does it
      # for the rest. An AI "none of these" that leads to a new book is flagged.
      class ProcessSubmission
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        ListAddFailed = Class.new(StandardError)

        EXTERNAL_SOURCE = "open_library"
        # Every identifier source but legacy, whose rows are known to be wrong.
        TRUSTED_SOURCES = ::Identifier::NON_LEGACY_SOURCES
        ALREADY_IN_LIST = ["Item already in list"].freeze
        MAX_ERROR_LENGTH = 1_000
        POSTGRES_ERRORS = [ActiveRecord::StatementInvalid, ActiveRecord::ConnectionNotEstablished].freeze

        def self.call(submission:, importer: ::DataImporters::Books::Book::Importer)
          new(submission: submission, importer: importer).call
        end

        # The job's last retry failed: the submission is failed with the error
        # recorded, unless it has finished meanwhile, and its flagged decisions
        # leave the review queue.
        def self.record_unexpected_failure(submission_id, error)
          message = failure_message(error)
          Rails.logger.error "Books::BookSubmission #{submission_id} failed: #{message}"
          ::Books::BookSubmission.where(id: submission_id, status: ::Books::BookSubmission::IN_PROGRESS_STATUSES)
            .update_all(status: :failed, error: message, updated_at: Time.current)
          clear_flags(submission_id)
        end

        def self.failure_message(error)
          "#{error.class.name}: #{Lookups::Names.scrubbed(error.message)}".first(MAX_ERROR_LENGTH)
        end

        # Reads the decision the submission holds from the row, never from a
        # loaded object, and writes no record attribute but the flag.
        def self.clear_flags(submission_id)
          kept = ::Books::BookSubmission.where(id: submission_id).pick(:match_decision_id)
          ::MatchDecision.needing_review
            .where(subject_type: ::Books::BookSubmission.polymorphic_name, subject_id: submission_id).where.not(id: kept)
            .update_all(needs_review: false, updated_at: Time.current)
        end

        def initialize(submission:, importer:)
          @submission = submission
          @importer = importer
        end

        def call
          result = run
          self.class.clear_flags(@submission.id)
          result
        rescue *POSTGRES_ERRORS
          raise
        rescue
          self.class.clear_flags(@submission.id)
          raise
        end

        private

        def run
          return done unless claim
          return finish(@submission.book) if @submission.book
          return cancel unless @submission.user && @submission.user_list

          resolved = ResolveInput.call(submission: @submission)
          case resolved.data[:outcome]
          when :needs_goodreads_page then outcome(:waiting_for_goodreads)
          when :no_record then needs_details
          when :unavailable then retry_or { needs_details }
          else settle(resolved.data)
          end
        end

        # Moves a queued or looking-up submission to looking up in one
        # conditional write, so a cancel landing now is not overwritten.
        def claim
          now = Time.current
          claimed = ::Books::BookSubmission.where(id: @submission.id, status: ::Books::BookSubmission::IN_PROGRESS_STATUSES)
            .where.not(review_status: :rejected)
            .update_all(["status = ?, processing_started_at = COALESCE(processing_started_at, ?), next_attempt_at = NULL, updated_at = ?",
              ::Books::BookSubmission.statuses[:looking_up], now, now])
          @submission.reload
          claimed.positive?
        end

        def settle(facts)
          match = finder.call(query: query_for(facts), subject: @submission)
          if retryable?(match) && (retried = retry_or { nil })
            return retried
          end
          return fail!("matching failed: #{match.reason.presence || match.sources_failed.join(", ")}") if hard_failure?(match)

          match.decision&.update!(needs_review: true) if match.unmatched? && match.decided_by == :ai
          flagged = match.decision&.needs_review?
          created = CreateBook.call(submission: @submission, resolved: facts, match: match, importer: @importer)
          case created.data[:outcome]
          when :aborted then done
          when :no_owner then cancel
          when :no_author then needs_details
          else
            keep_flag(match.decision) if flagged
            finish(created.data[:book])
          end
        end

        def finder
          ::DataImporters::Books::Book::Finder.new(identifier_sources: TRUSTED_SOURCES)
        end

        def query_for(facts)
          identifiers = facts[:identifiers]
          ::DataImporters::Books::Book::ImportQuery.new(
            title: facts[:title], subtitle: facts[:subtitle], author_names: facts[:author_names], year: facts[:year],
            isbn13: identifiers[:isbn13], isbn10: identifiers[:isbn10], asin: identifiers[:asin], goodreads_id: identifiers[:goodreads_id]
          )
        end

        # Only an unmatched answer is worth another try: a match is used at once
        # (a failed source can only have missed a better one, never created a
        # duplicate), and so is a book with nothing but Open Library down.
        def retryable?(match)
          hard_failure?(match) || (match.unmatched? && match.sources_failed.map(&:to_s).include?(EXTERNAL_SOURCE))
        end

        # An AI that failed, or a local source (the database, OpenSearch) that
        # could not answer: the finder may have missed a copy of the book, and
        # creating one now could duplicate it.
        def hard_failure?(match)
          match.unmatched? && (match.decided_by == :fallback || (match.sources_failed.map(&:to_s) - [EXTERNAL_SOURCE]).any?)
        end

        # A second job's clear_flags may have run between this run's finder and
        # its CreateBook; the decision the submission now holds keeps its flag.
        def keep_flag(decision)
          ::MatchDecision.where(id: decision.id, reviewed_at: nil).update_all(needs_review: true)
        end

        # The list add runs under two locks, taken in this order: the reader's user
        # row, then the book FOR KEY SHARE (read back after the lock). The book's
        # delete and the merger lock the book row first (Book#close_submissions,
        # Merger#lock_books), so a merge or delete either finished before the book
        # lock (the book is gone, and nothing is added) or waits for this
        # transaction. An item is never made for a book that is gone. A book merged
        # away since CreateBook is replaced by its survivor (the merger moved the
        # row); a deleted one leaves no item, and a provisional book's delete
        # already closed the row (rejected and cancelled), so there is nothing to
        # mark added.
        #
        # The user lock is FOR NO KEY UPDATE, not FOR UPDATE. A delete or merge that
        # holds the book updates a submission row a second time (the close and then
        # the nullify; the move and then the close), and Postgres re-checks that
        # row's foreign keys on the second UPDATE, taking FOR KEY SHARE on the
        # reader's users row. FOR UPDATE here conflicts with that, so the delete
        # waits for this run's user lock while this run waits for the book it holds:
        # a deadlock. FOR NO KEY UPDATE does not conflict with KEY SHARE, yet still
        # conflicts with the FOR UPDATE that DestructionInvalidator and OwnerMutation
        # take, so a reader's list mutations still take turns. OwnerMutation's own
        # FOR UPDATE, later in this transaction, is an upgrade of this lock. It
        # waits for a KEY SHARE on the reader's row, which a delete of another of
        # the reader's books, or any insert naming the reader, can hold; that wait
        # is harmless. A transaction that deletes several of the reader's books (a
        # Goodreads import revert of two) can hold that KEY SHARE from one and then
        # wait for the book this run holds: the two deadlock. Nothing is lost by
        # it, and if this run is the one Postgres stops, the job is retried.
        def finish(book)
          settled = nil
          item = nil
          ActiveRecord::Base.transaction do
            ::User.lock("FOR NO KEY UPDATE").where(id: @submission.user_id).pick(:id)
            settled = lock_book(book)
            item = add_to_list(settled) if settled
          end
          return done unless settled

          # Lookups only for the provisional book this run made: a book merged into
          # or promoted to the catalog since is not this feature's to enrich.
          StartLookups.call(book: settled) if @submission.created_book? && settled.id == book.id && settled.provisional?
          mark_added(item)
          done
        end

        def lock_book(book)
          id = book.id
          2.times do
            locked = ::Books::Book.lock("FOR KEY SHARE").find_by(id: id)
            return locked if locked

            id = ::Books::BookSubmission.where(id: @submission.id).pick(:book_id)
            return nil unless id
          end
          nil
        end

        # Conditional on the row still being open, so a close that landed since
        # is not overwritten (and an item the delete took with its book is not
        # written to a row that has gone cancelled).
        def mark_added(item)
          ::Books::BookSubmission.where(id: @submission.id, status: ::Books::BookSubmission::IN_PROGRESS_STATUSES)
            .update_all(status: ::Books::BookSubmission.statuses[:added], user_list_item_id: item&.id, next_attempt_at: nil, updated_at: Time.current)
        end

        def add_to_list(book)
          list = @submission.user_list
          user = @submission.user
          return unless list && user

          result = ::Services::UserLists::OwnerMutation.call(owner: user) do |tracker|
            added = ::Services::UserLists::AddItem.call(user_list: list, listable: book)
            tracker.track(added)
            added
          end
          return result.data[:item] if result.success?
          return ::UserListItem.find_by(user_list: list, listable: book) if result.errors == ALREADY_IN_LIST

          raise ListAddFailed, "could not add book #{book.id} to list #{list.id}: #{result.errors.join("; ")}"
        end

        def retry_or
          at = RetrySchedule.retry_later(@submission)
          return done if at == :closed
          return Result.new(success?: true, data: {outcome: :retry, retry_at: at}, errors: []) if at

          yield
        end

        def cancel
          Settle.call(@submission, status: :cancelled)
          done
        end

        def needs_details
          Settle.call(@submission, status: :needs_details, next_attempt_at: nil)
          done
        end

        def fail!(message)
          Rails.logger.error "Books::BookSubmission #{@submission.id} failed: #{message}"
          Settle.call(@submission, status: :failed, error: message.first(MAX_ERROR_LENGTH), next_attempt_at: nil)
          done
        end

        def done = outcome(:done)

        def outcome(name)
          Result.new(success?: true, data: {outcome: name}, errors: [])
        end
      end
    end
  end
end
