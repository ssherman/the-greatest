# frozen_string_literal: true

# Claims a configuration's CSV export row and enqueues the generate job
# (spec §8). Same shape as Services::RankingConfigurations::RequestRefresh:
# one conditional UPDATE is the claim, so two simultaneous callers -- three
# members clicking at once, or the nightly job racing a calculation -- produce
# one job. The stale clause reclaims a row wedged by a killed worker.
#
# The claim commits before the enqueue, so an unreachable Redis would leave
# the row `generating` for the whole stale window; an enqueue failure
# therefore releases it into `failed` with the reason.
#
# Model constants are root-anchored: inside Services::CsvExports a bare
# CsvExports resolves to this module.
module Services
  module CsvExports
    class RequestGenerate
      Result = Struct.new(:success?, :data, :errors, keyword_init: true)

      NOT_EXPORTABLE = "This ranking has no CSV export."
      ALREADY_GENERATING = "The export is already being generated."
      ENQUEUE_FAILED = "The export could not be queued. Try again in a moment."

      def self.call(ranking_configuration:)
        new(ranking_configuration: ranking_configuration).call
      end

      def initialize(ranking_configuration:)
        @config = ranking_configuration
      end

      def call
        return failure(nil, :not_exportable, NOT_EXPORTABLE) unless ::CsvExports::Registry.exportable?(config)

        export = find_or_create
        return failure(export, :already_generating, ALREADY_GENERATING) unless claim(export)

        begin
          ::CsvExports::GenerateJob.perform_async(export.id)
        rescue => error
          release(export, error)
          return failure(export, :enqueue_failed, ENQUEUE_FAILED)
        end

        Result.new(success?: true, data: {csv_export: export, reason: nil}, errors: [])
      end

      private

      attr_reader :config

      def statuses
        ::CsvExport.statuses
      end

      # Two callers can both miss the find; Rails' find_or_create_by! falls
      # through to create_or_find_by!, which rescues the unique-index violation
      # and returns the winner's row. That only holds because CsvExport has no
      # uniqueness validation (a validation would raise RecordInvalid instead).
      def find_or_create
        ::CsvExport.find_or_create_by!(ranking_configuration_id: config.id)
      end

      # CsvExport.claimable is the SQL twin of CsvExport#claimable?.
      def claim(export)
        claimed = ::CsvExport.claimable.where(id: export.id)
          .update_all(status: statuses[:generating], requested_at: Time.current)
        return false unless claimed == 1

        export.reload
        true
      end

      def release(export, error)
        Rails.logger.error "[Services::CsvExports::RequestGenerate] export #{export.id}: #{error.class}: #{error.message}"
        ::CsvExport.where(id: export.id).update_all(
          status: statuses[:failed],
          error_message: "Could not queue the export: #{error.message}".truncate(500)
        )
        export.reload
      end

      def failure(export, reason, message)
        Result.new(success?: false, data: {csv_export: export, reason: reason}, errors: [message])
      end
    end
  end
end
