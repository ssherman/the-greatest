# frozen_string_literal: true

# Placeholder so Services::CsvExports::RequestGenerate can be tested; Task 9
# replaces this with the real job.
module CsvExports
  class GenerateJob
    include Sidekiq::Job

    def perform(_csv_export_id)
    end
  end
end
