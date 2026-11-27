# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # An admin agent asking for a book the site may not have, optionally
      # targeting a books list at a position. Same pipeline as a reader's
      # Submit (ParseInput, InstantCheck, ProcessBookSubmissionJob), but the row
      # is origin admin, hangs off a ::Books::List (not a reader's user list),
      # and the reader's daily cap and replace rules do not apply.
      #
      # A refusal has errors and data[:reason]: :invalid (bad input, a position
      # that is not positive, or a position with no list) or :list (the list is
      # not a books list, or is auto-generated).
      #
      # data[:outcome] is
      #   :hits     the site already holds books that may be it (data[:books]);
      #             nothing is written,
      #   :existing the same request is still queued or being
      #             looked up on this list
      #             (data[:submission]),
      #   :created  a new queued submission (data[:submission]).
      #
      # The duplicate check and the insert happen under the user's row lock; the
      # job is queued after the commit. If Redis is down the row stays queued
      # and the RequeueStuckBookSubmissionsJob sweep starts it later.
      class AdminRequest
        Result = Struct.new(:success?, :data, :errors, keyword_init: true)

        LIST_MESSAGE = "That list cannot take a book from a request"
        MAX_POSITION = 2_147_483_647 # int4: a column limit, not a policy
        POSITION_MESSAGE = "Position must be a positive whole number and needs a list"

        def self.call(user:, params:, list: nil, position: nil, confirmed_new: false)
          new(user, params, list, position, confirmed_new).call
        end

        def initialize(user, params, list, position, confirmed_new)
          @user = user
          @params = params
          @list = list
          @position = position
          @confirmed_new = confirmed_new
        end

        def call
          return failure([LIST_MESSAGE], reason: :list) if @list && (!@list.is_a?(::Books::List) || @list.auto_generated?)
          return failure([POSITION_MESSAGE], reason: :invalid) unless position_ok?

          parsed = ParseInput.call(@params)
          return failure(parsed.errors, reason: :invalid) unless parsed.success?

          unless @confirmed_new
            books = InstantCheck.call(attributes: parsed.data[:attributes]).data[:books]
            return success(outcome: :hits, books: books) if books.any?
          end

          outcome, submission = @user.with_lock { write(parsed.data) }
          enqueue(submission) if outcome == :created
          success(outcome: outcome, submission: submission)
        rescue ActiveRecord::RecordInvalid => e
          failure(e.record.errors.full_messages, reason: :invalid)
        rescue ActiveRecord::InvalidForeignKey
          failure([LIST_MESSAGE], reason: :list)
        end

        private

        def position_ok?
          return true if @position.nil?
          return false unless @list

          @position.is_a?(Integer) && @position.between?(1, MAX_POSITION)
        end

        def write(parsed)
          existing = ::Books::BookSubmission.where(status: ::Books::BookSubmission::IN_PROGRESS_STATUSES).visible.origin_admin
            .where(user_id: @user.id, list_id: @list&.id, fingerprint: parsed[:fingerprint])
            .order(:id).first
          return [:existing, existing] if existing

          submission = ::Books::BookSubmission.create!(
            parsed[:attributes].merge(user: @user, origin: :admin, list: @list, list_position: @position,
              fingerprint: parsed[:fingerprint], status: :queued)
          )
          [:created, submission]
        end

        def enqueue(submission)
          ::Books::ProcessBookSubmissionJob.perform_async(submission.id)
        rescue => e
          Rails.logger.error("Book submission #{submission.id} was not queued: #{e.class}")
          Rails.error.report(e, handled: true, context: {submission_id: submission.id})
        end

        def success(data) = Result.new(success?: true, data: data, errors: [])

        def failure(errors, reason:) = Result.new(success?: false, data: {reason: reason}, errors: errors)
      end
    end
  end
end
