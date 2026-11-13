# Matches again the editions whose reimport_match verdict says "create a new book" but was recorded before
# MatchEdition looked for an English edition (it now asks for the English title of a translated edition and searches
# with it, so Der talentierte Mr. Ripley finds The Talented Mr. Ripley instead of becoming a German duplicate).
# .enqueue queues them 100 at a time. Each verdict is superseded, then MatchEdition records over it; a retry or an
# error restores it, so the next enqueue picks it up again. Verdicts an admin reviewed, applied ones, and ones that
# already carry an English check are left alone. Does nothing while the re-import gate is off.
class Books::GoodreadsReimport::RecheckCreatesJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  BATCH_SIZE = 100

  def self.candidates
    ::Books::RepairVerdict.current.where(kind: :reimport_match, status: [:approved, :proposed], reviewed_at: nil, applied_at: nil)
      .where("payload->>'outcome' = 'create'").where.not("payload ? 'english_title'")
  end

  # Returns how many verdicts were queued.
  def self.enqueue(limit: nil)
    ids = candidates.order(:id).pluck(:id)
    ids = ids.first(limit) if limit
    ids.each_slice(BATCH_SIZE) { |batch| perform_async(batch) }
    ids.size
  end

  def perform(verdict_ids)
    return unless Rails.configuration.x.goodreads_reimport.enabled

    counts = Hash.new(0)
    self.class.candidates.where(id: verdict_ids).find_each do |verdict|
      counts[recheck(verdict)] += 1
    end
    Rails.logger.info("recheck_creates batch: #{verdict_ids.size} verdicts — " + counts.map { |key, count| "#{key} #{count}" }.join(", "))
  end

  private

  def recheck(verdict)
    edition = ::Books::GoodreadsEdition.find_by(id: verdict.payload["goodreads_edition_id"])
    return :no_edition unless edition

    verdict.update!(superseded_at: Time.current)
    outcome = ::Services::Books::GoodreadsReimport::MatchEdition.call(edition: edition).data[:outcome]
    verdict.update!(superseded_at: nil) if outcome == :retry
    outcome
  rescue => e
    verdict.update!(superseded_at: nil)
    Rails.logger.error("recheck_creates: verdict #{verdict.id} failed: #{e.class}: #{e.message}")
    :errors
  end
end
