# frozen_string_literal: true

# Generates one configuration's pre-built CSV. `retry: false` because the row
# carries the outcome (spec §8): a silent Sidekiq retry would run while the
# admin card still said "failed", and every trigger (calculation, nightly,
# download, admin button) re-claims a failed row anyway.
module CsvExports
  class GenerateJob
    include Sidekiq::Job

    sidekiq_options queue: :low, retry: false

    def perform(csv_export_id)
      export = ::CsvExport.find_by(id: csv_export_id)
      return if export.nil? # deleted while queued -- not a failure

      result = Services::CsvExports::Generate.call(csv_export: export)
      raise "CSV export #{csv_export_id} failed: #{result.errors.join(", ")}" unless result.success?
    end
  end
end
