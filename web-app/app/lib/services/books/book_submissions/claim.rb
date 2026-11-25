# frozen_string_literal: true

module Services
  module Books
    module BookSubmissions
      # Hands an agent a batch of submissions to review under one lease token,
      # modelled on Services::EnrichmentQueue::Claim: each pass picks its rows
      # FOR UPDATE SKIP LOCKED, oldest first, and marks them claimed in the same
      # transaction, so a concurrent claim skips them instead of waiting for them
      # or taking the same ones.
      #
      # The rows are those `claimable` selects: a pending review, or a request
      # with no book (needs_details, failed), with no live lease. A row flagged
      # needs_human is never one of them.
      #
      # `claims` counts the times a row was handed out. It is its own column
      # because `attempts` belongs to the lookup's retry schedule while a request
      # is in progress, so a row that retried twice would look half-abandoned the
      # first time an agent saw it. A row already claimed MAX_CLAIMS times is
      # abandoned (its leases expired unanswered each time): it becomes
      # needs_human, noted "abandoned by agents", and leaves a hole in the batch,
      # so up to MAX_PASSES passes top it up.
      class Claim
        Result = Lease::Result

        MAX_LIMIT = 25
        DEFAULT_LIMIT = 10
        MAX_CLAIMS = 3
        MAX_PASSES = 3
        ABANDONED = "abandoned by agents"

        def self.call(user:, limit: DEFAULT_LIMIT)
          new(user: user, limit: limit).call
        end

        def initialize(user:, limit:)
          @user = user
          @limit = limit
        end

        def call
          unless @limit.is_a?(Integer) && (1..MAX_LIMIT).cover?(@limit)
            return Lease.failure(:invalid, "limit must be between 1 and #{MAX_LIMIT}")
          end

          @token = SecureRandom.uuid
          @expires_at = Time.current + Lease::DURATION
          items = []
          needed = @limit
          MAX_PASSES.times do
            picked, abandoned = pass(needed)
            items.concat(picked)
            needed = abandoned
            break if needed.zero?
          end

          Lease.success(
            items: items,
            lease_token: items.empty? ? nil : @token,
            lease_expires_at: items.empty? ? nil : @expires_at,
            remaining: ::Books::BookSubmission.claimable.count
          )
        end

        private

        # One transaction: pick, mark. Returns [rows handed out, rows abandoned].
        def pass(needed)
          ::Books::BookSubmission.transaction do
            ids = ::Books::BookSubmission.claimable.order(:created_at, :id).limit(needed).lock("FOR UPDATE SKIP LOCKED").pluck(:id)
            next [[], 0] if ids.empty?

            rows = ::Books::BookSubmission.where(id: ids).index_by(&:id).values_at(*ids)
            abandoned, claimable = rows.partition { |row| row.claims >= MAX_CLAIMS }
            abandon(abandoned)
            mark_claimed(claimable)
            [claimable.map(&:reload), abandoned.size]
          end
        end

        def abandon(rows)
          return if rows.empty?

          ::Books::BookSubmission.where(id: rows.map(&:id)).update_all(
            review_status: :needs_human, review_note: ABANDONED, reviewed_via: :system, reviewed_by_id: nil,
            reviewed_at: Time.current, lease_token: nil, lease_expires_at: nil, updated_at: Time.current
          )
        end

        def mark_claimed(rows)
          return if rows.empty?

          ::Books::BookSubmission.where(id: rows.map(&:id)).update_all(
            ["lease_token = ?, lease_expires_at = ?, claimed_by_id = ?, claims = claims + 1, updated_at = ?",
              @token, @expires_at, @user.id, Time.current]
          )
        end
      end
    end
  end
end
