# frozen_string_literal: true

# Hourly (config/schedule.yml): load the model the home server last published,
# if it is new (spec 2 §5). Idempotent -- LoadModel skips a known version.
# With none of the RECOMMENDATIONS_R2_* variables set it logs and skips; a
# partial set still raises Store::NotConfigured.
module Recommendations
  class LoadModelJob
    include Sidekiq::Job

    # The cron entry is the retry; Sidekiq retries would repeat the work on top of it.
    sidekiq_options queue: :low, retry: false

    def perform(domain = "books")
      store = Store::R2.from_env
      if store.nil?
        Rails.logger.warn "[Recommendations::LoadModelJob] recommendations store not configured; skipping"
        return
      end

      result = LoadModel.call(domain: domain, store: store)
      raise "Recommendations::LoadModelJob #{domain}: #{result.errors.join(", ")}" unless result.success?

      Rails.logger.info "[Recommendations::LoadModelJob] #{domain}: #{result.data[:loaded] ? "loaded #{result.data[:version]} (#{result.data[:rows]} rows)" : "nothing to load (#{result.data[:reason]})"}"
    end
  end
end
