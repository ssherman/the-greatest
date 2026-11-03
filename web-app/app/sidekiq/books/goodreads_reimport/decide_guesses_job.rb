# Decides the hand-added entries of mixed books for the re-import
# (Services::Books::GoodreadsReimport::DecideGuesses; .enqueue queues the mixed verdicts 100 at a time).
# Records verdicts only. Does nothing while the re-import gate is off. A book whose rows are not all decided yet
# answers "waiting" and is picked up by the next enqueue; one book failing is logged and the batch carries on.
class Books::GoodreadsReimport::DecideGuessesJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  BATCH_SIZE = 100
  OUTCOMES = %i[decided kept waiting skipped].freeze
  REIMPORT_MIXED_KIND = ::Books::RepairVerdict.kinds.fetch("reimport_mixed")

  # Approved, current mixed verdicts. Returns how many were queued.
  def self.enqueue
    ids = ::Books::RepairVerdict.where(kind: REIMPORT_MIXED_KIND, status: :approved, superseded_at: nil).order(:id).pluck(:id)
    ids.each_slice(BATCH_SIZE) { |batch| perform_async(batch) }
    ids.size
  end

  def perform(verdict_ids)
    return unless Rails.configuration.x.goodreads_reimport.enabled

    counts = OUTCOMES.index_with(0).merge(errors: 0)
    ::Books::RepairVerdict.where(id: verdict_ids).find_each do |verdict|
      outcome = ::Services::Books::GoodreadsReimport::DecideGuesses.call(mixed_verdict: verdict).data[:outcome]
      counts[outcome] += 1 if counts.key?(outcome)
    rescue => e
      counts[:errors] += 1
      Rails.logger.error("decide_guesses: verdict #{verdict.id} failed: #{e.class}: #{e.message}")
    end
    Rails.logger.info("decide_guesses batch: #{verdict_ids.size} verdicts — " + counts.map { |key, count| "#{key} #{count}" }.join(", "))
  end
end
