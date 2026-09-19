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
      ::RankingConfiguration.global.active.find_each do |config|
        next unless Registry.exportable?(config)

        Services::CsvExports::RequestGenerate.call(ranking_configuration: config)
      end
    end
  end
end
