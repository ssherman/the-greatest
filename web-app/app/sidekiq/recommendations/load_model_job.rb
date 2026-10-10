# frozen_string_literal: true

# Hourly (config/schedule.yml): load the model the home server last published,
# if it is new (spec 2 §5). Idempotent -- LoadModel skips a known version.
module Recommendations
  class LoadModelJob
    include Sidekiq::Job

    sidekiq_options queue: :low

    def perform(domain = "books")
      result = LoadModel.call(domain: domain, store: Store.default)
      raise "Recommendations::LoadModelJob #{domain}: #{result.errors.join(", ")}" unless result.success?

      Rails.logger.info "[Recommendations::LoadModelJob] #{domain}: #{result.data[:loaded] ? "loaded #{result.data[:version]} (#{result.data[:rows]} rows)" : "nothing to load (#{result.data[:reason]})"}"
    end
  end
end
