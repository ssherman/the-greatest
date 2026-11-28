# frozen_string_literal: true

# Runs Services::Books::AmazonBookIdentifiersRepair one chunk at a time and
# queues the next chunk itself, carrying the running totals, so a deploy only
# costs the chunk in flight (Sidekiq pushes it back) and nothing is redone.
# Queued by books:amazon_book_identifiers_repair. Progress and the final totals
# go to the worker log. `low`, no retry: a rerun is safe and starts over.
class Books::AmazonBookIdentifiersRepairJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: false

  COUNTS = Services::Books::AmazonBookIdentifiersRepair::COUNTS.map(&:to_s).freeze

  def perform(run_id, dry_run, after_id = 0, totals = {})
    data = Services::Books::AmazonBookIdentifiersRepair.call(after_id: after_id, dry_run: dry_run).data
    totals = COUNTS.to_h { |key| [key, totals[key].to_i + data[key.to_sym]] }
    line = COUNTS.map { |key| "#{totals[key]} #{key.tr("_", " ")}" }.join(", ")
    mode = dry_run ? "dry run" : "apply"

    if data[:done]
      Rails.logger.info("Amazon book identifiers repair #{run_id} (#{mode}) finished: #{line}")
    else
      Rails.logger.info("Amazon book identifiers repair #{run_id} (#{mode}) through edition #{data[:last_id]}: #{line}")
      self.class.perform_async(run_id, dry_run, data[:last_id], totals)
    end
  end
end
