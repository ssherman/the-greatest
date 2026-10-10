# frozen_string_literal: true

# Nightly (config/schedule.yml): write the domain's positive pairs to the
# recommendations store for the home server's trainer (spec 2 §3). Store.default
# raises when R2 is not configured, which is the right outcome in production.
module Recommendations
  class ExportInteractionsJob
    include Sidekiq::Job

    # The cron entry is the retry; Sidekiq retries would repeat the work on top of it.
    sidekiq_options queue: :low, retry: false

    def perform(domain = "books")
      result = Export.call(domain: domain, store: Store.default)
      raise "Recommendations::ExportInteractionsJob #{domain}: #{result.errors.join(", ")}" unless result.success?

      Rails.logger.info "[Recommendations::ExportInteractionsJob] #{domain}: #{result.data[:rows]} rows to #{result.data[:key]}"
    end
  end
end
