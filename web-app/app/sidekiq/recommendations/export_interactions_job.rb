# frozen_string_literal: true

# Nightly (config/schedule.yml): write the domain's positive pairs to the
# recommendations store for the home server's trainer (spec 2 §3). With none
# of the RECOMMENDATIONS_R2_* variables set (production before the bucket
# exists) it logs and skips, so the cron is not an error every night; a
# partial set still raises Store::NotConfigured, since that is a mistake.
# The rake task keeps the strict Store.default.
module Recommendations
  class ExportInteractionsJob
    include Sidekiq::Job

    # The cron entry is the retry; Sidekiq retries would repeat the work on top of it.
    sidekiq_options queue: :low, retry: false

    def perform(domain = "books")
      store = Store::R2.from_env
      if store.nil?
        Rails.logger.warn "[Recommendations::ExportInteractionsJob] recommendations store not configured; skipping"
        return
      end

      result = Export.call(domain: domain, store: store)
      raise "Recommendations::ExportInteractionsJob #{domain}: #{result.errors.join(", ")}" unless result.success?

      Rails.logger.info "[Recommendations::ExportInteractionsJob] #{domain}: #{result.data[:rows]} rows to #{result.data[:key]}"
    end
  end
end
