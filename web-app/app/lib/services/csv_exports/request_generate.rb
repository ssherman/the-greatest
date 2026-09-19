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
# A caller whose data changed (a finished ranking calculation) passes
# `rerun_if_generating: true`: when its claim is refused by a run already in
# flight, it flags the row `rerun_requested` instead of walking away, and
# GenerateJob re-requests a generation after that run -- the in-flight run
# plucked its ids before the new ranks landed, so its file is already stale.
# Every claim clears the flag: a fresh run satisfies any pending request.
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

      def self.call(ranking_configuration:, rerun_if_generating: false)
        new(ranking_configuration: ranking_configuration, rerun_if_generating: rerun_if_generating).call
      end

      def initialize(ranking_configuration:, rerun_if_generating: false)
        @config = ranking_configuration
        @rerun_if_generating = rerun_if_generating
      end

      def call
        return failure(nil, :not_exportable, NOT_EXPORTABLE) unless ::CsvExports::Registry.exportable?(config)

        export = find_or_create
        return failure(export, :already_generating, ALREADY_GENERATING) unless claim_or_request_rerun(export)

        begin
          ::CsvExports::GenerateJob.perform_async(export.id)
        rescue => error
          release(export, error)
          return failure(export, :enqueue_failed, ENQUEUE_FAILED)
        end

        Result.new(success?: true, data: {csv_export: export, reason: nil}, errors: [])
      end

      private

      attr_reader :config, :rerun_if_generating

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

      # CsvExport.claimable is the SQL twin of CsvExport#claimable?. The same
      # UPDATE clears any pending rerun request: this run satisfies it.
      def claim(export)
        claimed = ::CsvExport.claimable.where(id: export.id)
          .update_all(status: statuses[:generating], requested_at: Time.current, rerun_requested: false)
        return false unless claimed == 1

        export.reload
        true
      end

      # A refused claim ends here unless the caller asked for a rerun: then the
      # flag lands on the still-generating row, or -- if that run finished
      # between the two statements -- the row is claimed after all.
      def claim_or_request_rerun(export)
        return true if claim(export)
        return false unless rerun_if_generating
        return false if request_rerun(export)

        claim(export)
      end

      # A data-changing caller (a finished ranking calculation) that lost the
      # claim asks the running job to go again when it is done: the in-flight
      # run plucked its ids before the new ranks landed. Guarded by
      # `status = generating` so the flag can only land on a row the running
      # job has not finished with yet -- GenerateJob reads it after its run.
      # Returns false when the row is no longer generating, so the caller
      # claims it instead.
      def request_rerun(export)
        ::CsvExport.where(id: export.id, status: statuses[:generating]).update_all(rerun_requested: true) == 1
      end

      # Scoped to the claim this call holds (claim reloaded requested_at from
      # the row), so a stale reclaim by another caller in the meantime is never
      # clobbered back to failed.
      def release(export, error)
        Rails.logger.error "[Services::CsvExports::RequestGenerate] export #{export.id}: #{error.class}: #{error.message}"
        ::CsvExport.where(id: export.id, status: statuses[:generating], requested_at: export.requested_at).update_all(
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
