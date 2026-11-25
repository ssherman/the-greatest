# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # One reader asking for a book the site may not have. Runs in the web
      # request, so it reads Postgres only (InstantCheck) and queues the real
      # work for ProcessBookSubmissionJob.
      #
      # A refusal has errors and data[:reason]: :limit when the daily cap was hit,
      # :gone when the list was deleted after the caller looked it up (the insert's
      # foreign key is what notices; nothing is written).
      #
      # data[:outcome] is
      #   :hits     the site already holds up to three books that may be it
      #             (data[:books]); no row is made and nothing is counted,
      #   :existing the reader already has this request open on this list
      #             (data[:submission]); nothing is made or counted,
      #   :created  a new queued submission (data[:submission]).
      #
      # The duplicate check, the daily count, the insert and the cancel of a
      # replaced row all happen under the user's row lock, so two requests at
      # once cannot both pass the cap or both make the same request. The job is
      # queued after the commit; if Redis is down the row stays queued and the
      # RequeueStuckBookSubmissionsJob sweep starts it later, so the reader
      # still gets success.
      class Submit
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        REPLACEABLE_STATUSES = %w[needs_details failed].freeze
        LIMIT_MESSAGE = "You have added a lot of books today. Try again tomorrow"
        GONE_MESSAGE = "That list no longer exists"

        def self.call(user:, list:, params:, confirmed_new: false, replaces: nil)
          new(user, list, params, confirmed_new, replaces).call
        end

        def initialize(user, list, params, confirmed_new, replaces)
          @user = user
          @list = list
          @params = params
          @confirmed_new = confirmed_new
          @replaces = replaces
        end

        def call
          parsed = ParseInput.call(@params)
          return failure(parsed.errors) unless parsed.success?

          unless @confirmed_new
            books = InstantCheck.call(attributes: parsed.data[:attributes]).data[:books]
            return success(outcome: :hits, books: books) if books.any?
          end

          outcome, submission, error = @user.with_lock { write(parsed.data) }
          return failure([error], reason: :limit) if error

          enqueue(submission) if outcome == :created
          success(outcome: outcome, submission: submission)
        rescue ActiveRecord::RecordInvalid => e
          failure(e.record.errors.full_messages)
        rescue ActiveRecord::InvalidForeignKey
          failure([GONE_MESSAGE], reason: :gone)
        end

        private

        # Returns [outcome, submission, error]; a return from inside the lock's
        # transaction block would be ambiguous, so it hands back a value.
        def write(parsed)
          replaced = replaceable_row
          open = ::Books::BookSubmission.open.visible
            .where(user_id: @user.id, user_list_id: @list.id, fingerprint: parsed[:fingerprint])
          open = open.where.not(id: replaced.id) if replaced
          existing = open.order(:id).first
          return [:existing, existing, nil] if existing

          since = 24.hours.ago
          return [nil, nil, LIMIT_MESSAGE] if ::Books::BookSubmission.where(user_id: @user.id).where("created_at > ?", since).count >= limit

          submission = ::Books::BookSubmission.create!(
            parsed[:attributes].merge(user: @user, user_list: @list, fingerprint: parsed[:fingerprint], status: :queued)
          )
          Cancel.call(user: @user, id: replaced.id, statuses: REPLACEABLE_STATUSES, list: @list) if replaced
          [:created, submission, nil]
        end

        # The reader's own needs_details or failed row on this list, with no
        # book; anything else named by `replaces` is ignored.
        def replaceable_row
          id = @replaces.to_s[/\A\d{1,18}\z/]
          return unless id

          ::Books::BookSubmission.where(id: id, user_id: @user.id, user_list_id: @list.id, status: REPLACEABLE_STATUSES, book_id: nil).first
        end

        def limit = Rails.application.config.x.book_submissions.daily_limit

        def enqueue(submission)
          ::Books::ProcessBookSubmissionJob.perform_async(submission.id)
        rescue => e
          Rails.logger.error("Book submission #{submission.id} was not queued: #{e.class}")
          Rails.error.report(e, handled: true, context: {submission_id: submission.id})
        end

        def success(data) = Result.new(success?: true, data: data, errors: [])

        def failure(errors, reason: nil) = Result.new(success?: false, data: {reason: reason}, errors: errors)
      end
    end
  end
end
