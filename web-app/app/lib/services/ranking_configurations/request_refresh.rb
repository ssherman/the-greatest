# frozen_string_literal: true

# Claims a user-owned configuration's refresh lock and enqueues the job.
#
# The claim is one conditional UPDATE: two simultaneous callers serialize on
# the row lock and the loser re-evaluates the WHERE against the winner's
# committed value, so at most one caller ever sees a changed row. The stale
# clause reclaims a row wedged by a worker killed mid-run, which no rescue in
# the job can catch.
#
# The claim commits before the enqueue, so an unreachable Redis would
# otherwise leave the row "queued" -- and every Refresh click rejected -- for
# the whole stale window. An enqueue failure therefore releases the claim
# into `failed` with the reason, which the manage page shows and the button
# can retry.
#
# Model constants are root-anchored: Services::RankingConfiguration is an
# existing module, so a bare RankingConfiguration here would resolve to it.
module Services
  module RankingConfigurations
    class RequestRefresh
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      ALREADY_RUNNING = "A refresh is already running for this ranking."
      ENQUEUE_FAILED = "The refresh could not be queued. Try again in a moment."

      def self.call(config:)
        new(config: config).call
      end

      def initialize(config:)
        @config = config
      end

      def call
        return failure(:already_running, ALREADY_RUNNING) unless claim

        begin
          ::RankingConfigurations::RefreshJob.perform_async(config.id)
        rescue => error
          release(error)
          return failure(:enqueue_failed, ENQUEUE_FAILED)
        end

        Result.new(success?: true, data: {ranking_configuration: config, reason: nil}, errors: [])
      end

      private

      attr_reader :config

      def statuses
        ::RankingConfiguration.refresh_statuses
      end

      def claim
        claimed = ::RankingConfiguration.where(id: config.id)
          .where("refresh_status IN (:free) OR refresh_requested_at < :stale",
            free: [statuses[:idle], statuses[:failed]],
            stale: ::RankingConfiguration::REFRESH_STALE_AFTER.ago)
          .update_all(refresh_status: statuses[:queued], refresh_requested_at: Time.current, last_refresh_error: nil)
        return false unless claimed == 1

        config.reload
        true
      end

      def release(error)
        Rails.logger.error "[Services::RankingConfigurations::RequestRefresh] configuration #{config.id}: #{error.class}: #{error.message}"
        ::RankingConfiguration.where(id: config.id).update_all(
          refresh_status: statuses[:failed],
          last_refresh_error: "Could not queue the refresh: #{error.message}".truncate(500)
        )
        config.reload
      end

      def failure(reason, message)
        Result.new(success?: false, data: {ranking_configuration: config, reason: reason}, errors: [message])
      end
    end
  end
end
