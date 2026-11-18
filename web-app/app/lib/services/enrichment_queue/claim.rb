# frozen_string_literal: true

module Services
  module EnrichmentQueue
    # Hands an agent a batch of queue rows under one lease token. Several agents
    # claim at once, so each pass picks its rows with FOR UPDATE SKIP LOCKED and
    # marks them claimed in the same transaction: the row locks are held until
    # the rows say "claimed", and a concurrent claim skips them instead of
    # waiting or taking the same ones.
    #
    # user is required but may be nil: the paid research worker passes nil, as it
    # has no admin behind it. A caller must say so rather than forget it.
    #
    # A row that is abandoned MAX_ATTEMPTS times (its lease expired each time)
    # is closed, and a row whose gap was filled meanwhile is closed too. Both
    # leave a hole in the batch, so up to MAX_PASSES passes top it up.
    class Claim
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      MAX_LIMIT = 25
      DEFAULT_LIMIT = 10
      MAX_PASSES = 3

      def self.call(kind:, user:, limit: DEFAULT_LIMIT)
        new(kind: kind, limit: limit, user: user).call
      end

      def initialize(kind:, limit:, user:)
        @kind = kind
        @limit = limit
        @user = user
      end

      def call
        return failure("limit must be between 1 and #{MAX_LIMIT}") unless @limit.is_a?(Integer) && (1..MAX_LIMIT).cover?(@limit)

        type = Registry.fetch(@kind)
        @token = SecureRandom.uuid
        @expires_at = Time.current + ::EnrichmentRequest::LEASE
        items = []
        needed = @limit
        MAX_PASSES.times do
          picked, closed = pass(type, needed)
          items.concat(picked)
          needed = closed
          break if needed.zero?
        end

        Result.new(success?: true, errors: [], data: {
          items: items,
          lease_token: items.empty? ? nil : @token,
          lease_expires_at: items.empty? ? nil : @expires_at,
          remaining: ::EnrichmentRequest.for_kind(@kind).claimable.count
        })
      rescue Registry::UnknownKind => e
        failure(e.message)
      end

      private

      def failure(message) = Result.new(success?: false, data: nil, errors: [message])

      # One transaction: pick, mark, check. Returns [rows handed out, rows closed].
      def pass(type, needed)
        ::EnrichmentRequest.transaction do
          ids = ::EnrichmentRequest.for_kind(@kind).claimable.order(:priority, :id).limit(needed)
            .lock("FOR UPDATE SKIP LOCKED").pluck(:id)
          return [[], 0] if ids.empty?

          rows = ::EnrichmentRequest.where(id: ids).index_by(&:id).values_at(*ids)
          abandoned, claimable = rows.partition { |row| row.attempts >= ::EnrichmentRequest::MAX_ATTEMPTS }
          abandoned.each { |row| close(row, status: :skipped, outcome: "abandoned") }
          mark_claimed(claimable)

          handed_out = []
          closed = abandoned.size
          claimable.each do |row|
            record = row.enrichable
            if record.nil?
              row.delete
              closed += 1
            elsif type.still_needed?(record)
              handed_out << row
            else
              close(row, status: :done, outcome: "no_longer_needed")
              closed += 1
            end
          end
          [handed_out, closed]
        end
      end

      def mark_claimed(rows)
        return if rows.empty?

        ::EnrichmentRequest.where(id: rows.map(&:id)).update_all([
          "status = ?, lease_token = ?, lease_expires_at = ?, claimed_by_id = ?, attempts = attempts + 1, updated_at = ?",
          ::EnrichmentRequest.statuses.fetch("claimed"), @token, @expires_at, @user&.id, Time.current
        ])
        rows.each(&:reload)
      end

      def close(row, status:, outcome:)
        row.update!(status: status, outcome: outcome, resolved_via: :system, resolved_at: Time.current,
          lease_token: nil, lease_expires_at: nil)
      end
    end
  end
end
