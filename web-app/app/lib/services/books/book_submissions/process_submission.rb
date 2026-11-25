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
      # still added.
      #
      # Retries are for a source that is down (see RetrySchedule): the
      # resolve step unavailable, a finder that fell back (its AI failed) or
      # had a local source fail, or Open Library failing with nothing matched.
      # When the window has passed the resolve step's unavailability is
      # needs_details, a fallback or a failed local source is failed, and
      # Open Library alone goes on to create. A match is used at once whatever
      # its confidence: the finder always decides, and the decision's own
      # review flag audits it.
      #
      # A finder run that goes unused (a retry, a cancel, a book with no
      # author) is taken out of the review queue, as GoodreadsImports::
      # ResolveEdition does, and an AI "none of these" that leads to a new book
      # is flagged for review. Any other error is raised for the job's retries.
      class ProcessSubmission
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)
        ListAddFailed = Class.new(StandardError)

        EXTERNAL_SOURCE = "open_library"
        # Every identifier source but legacy, whose rows are known to be wrong.
        TRUSTED_SOURCES = ::Identifier::NON_LEGACY_SOURCES
        ALREADY_IN_LIST = ["Item already in list"].freeze
        MAX_ERROR_LENGTH = 1_000

        def self.call(submission:, importer: ::DataImporters::Books::Book::Importer)
          new(submission: submission, importer: importer).call
        end

        # The job's last retry failed: the submission is failed with the error
        # recorded, unless it has finished meanwhile.
        def self.record_unexpected_failure(submission_id, error)
          message = "#{error.class.name}: #{Lookups::Names.scrubbed(error.message)}".first(MAX_ERROR_LENGTH)
          Rails.logger.error "Books::BookSubmission #{submission_id} failed: #{message}"
          ::Books::BookSubmission.where(id: submission_id, status: ::Books::BookSubmission::IN_PROGRESS_STATUSES)
            .update_all(status: ::Books::BookSubmission.statuses[:failed], error: message, updated_at: Time.current)
        end

        def initialize(submission:, importer:)
          @submission = submission
          @importer = importer
        end

        def call
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

        private

        # Moves a queued or looking-up submission to looking up in one
        # conditional write, so a cancel landing now is not overwritten.
        def claim
          now = Time.current
          claimed = ::Books::BookSubmission.where(id: @submission.id, status: ::Books::BookSubmission::IN_PROGRESS_STATUSES)
            .update_all(["status = ?, processing_started_at = COALESCE(processing_started_at, ?), next_attempt_at = NULL, updated_at = ?",
              ::Books::BookSubmission.statuses[:looking_up], now, now])
          @submission.reload
          claimed.positive?
        end

        def settle(facts)
          match = finder.call(query: query_for(facts), subject: @submission)
          if (hard_failure?(match) || open_library_only_failure?(match)) && (retried = retry_or { nil })
            supersede(match.decision)
            return retried
          end
          return fail!("matching failed: #{match.reason.presence || match.sources_failed.join(", ")}") if hard_failure?(match)

          match.decision&.update!(needs_review: true) if match.unmatched? && match.decided_by == :ai
          created = CreateBook.call(submission: @submission, resolved: facts, match: match, importer: @importer)
          case created.data[:outcome]
          when :aborted
            supersede(match.decision)
            done
          when :no_author
            supersede(match.decision)
            needs_details
          else finish(created.data[:book])
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

        # An AI that failed, or a local source (the database, OpenSearch) that
        # could not answer: the finder may have missed a copy of the book.
        def hard_failure?(match)
          match.decided_by == :fallback || (match.sources_failed.map(&:to_s) - [EXTERNAL_SOURCE]).any?
        end

        # Open Library is only another place to look: with a match in hand it
        # changes nothing, and with none it is worth a retry.
        def open_library_only_failure?(match)
          match.unmatched? && match.sources_failed.map(&:to_s).include?(EXTERNAL_SOURCE)
        end

        def finish(book)
          supersede_older(@submission.match_decision)
          item = add_to_list(book)
          StartLookups.call(book: book) if @submission.created_book?
          @submission.update!(status: :added, user_list_item: item, next_attempt_at: nil)
          done
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

        # A decision about this submission that did not become its own: this
        # run's when it went unused, and any a crashed earlier run left.
        def supersede(decision)
          decision.update!(needs_review: false) if decision&.needs_review?
        end

        def supersede_older(decision)
          return if decision.nil?

          ::MatchDecision.needing_review.where(subject: @submission).where(id: ...decision.id)
            .update_all(needs_review: false, updated_at: Time.current)
        end

        def retry_or
          at = RetrySchedule.retry_later(@submission)
          return Result.new(success?: true, data: {outcome: :retry, retry_at: at}, errors: []) if at

          yield
        end

        def cancel
          @submission.update!(status: :cancelled)
          done
        end

        def needs_details
          @submission.update!(status: :needs_details, next_attempt_at: nil)
          done
        end

        def fail!(message)
          Rails.logger.error "Books::BookSubmission #{@submission.id} failed: #{message}"
          @submission.update!(status: :failed, error: message.first(MAX_ERROR_LENGTH), next_attempt_at: nil)
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
