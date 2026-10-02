# frozen_string_literal: true

# Nightly reconciliation (spec D5): title fixes, author merges and category
# edits change a file's contents without any ranking calculation, and nothing
# cheap detects that at download time. Global configurations only -- a
# user-owned one regenerates on its owner's refresh.
module CsvExports
  class RefreshGlobalJob
    include Sidekiq::Job

    sidekiq_options queue: :low

    def perform
      requested = 0
      failures = []

      ::RankingConfiguration.global.active.find_each do |config|
        next unless Registry.exportable?(config)

        result = Services::CsvExports::RequestGenerate.call(ranking_configuration: config)
        requested += 1 if result.success?
      rescue => e
        Rails.logger.error "[CsvExports::RefreshGlobalJob] configuration #{config.id}: #{e.class}: #{e.message}"
        failures << config.id
      end

      Rails.logger.info "[CsvExports::RefreshGlobalJob] requested #{requested} export(s); #{failures.size} failure(s)"
      raise "CsvExports::RefreshGlobalJob failed for configuration(s) #{failures.join(", ")}" if failures.any?
    end
  end
end
