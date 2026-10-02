# frozen_string_literal: true

# Generates one configuration's pre-built CSV. `retry: false` because the row
# carries the outcome (spec §8): a silent Sidekiq retry would run while the
# admin card still said "failed", and every trigger (calculation, nightly,
# download, admin button) re-claims a failed row anyway. With retry: false the
# raise is logged by Sidekiq and the job is acknowledged -- it does not reach
# the Dead set; the admin Regenerate button is the retry.
module CsvExports
  class GenerateJob
    include Sidekiq::Job

    sidekiq_options queue: :low, retry: false

    def perform(csv_export_id)
      export = ::CsvExport.find_by(id: csv_export_id)
      return if export.nil? # deleted while queued -- not a failure

      result = Services::CsvExports::Generate.call(csv_export: export)
      # Another worker re-claimed the row during a long run and owns it now,
      # including any rerun request.
      return if result.data[:reason] == :claim_lost

      # A calculation landed while this run was in flight; its ranks are not
      # in the file just written. Whether this run succeeded or failed, go again.
      Services::CsvExports::RequestGenerate.call(ranking_configuration: export.ranking_configuration) if export.reload.rerun_requested?

      raise "CSV export #{csv_export_id} failed: #{result.errors.join(", ")}" unless result.success?
    end
  end
end
