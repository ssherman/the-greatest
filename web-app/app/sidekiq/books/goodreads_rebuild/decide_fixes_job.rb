# Decides a batch of derived books for the Goodreads rebuild's fixes
# (Services::Books::GoodreadsRebuild::DecideFixes queues them, 100 at a time).
# Records verdicts and changes no book, except that a same-person export spelling is added to the author's alternate names. One book failing is logged and the
# batch carries on; a book whose finder run failed is counted as "retry" and
# simply comes up again in the next run.
class Books::GoodreadsRebuild::DecideFixesJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 3

  OUTCOMES = %i[merge fix same_author kept skipped retry].freeze

  def perform(book_ids)
    counts = OUTCOMES.index_with(0).merge(errors: 0)
    surveys = ::Books::RebuildBookSurvey.where(book_id: book_ids).includes(:book).index_by(&:book_id)
    book_ids.each do |id|
      survey = surveys[id]
      next unless survey&.book

      outcome = ::Services::Books::GoodreadsRebuild::DecideFix.call(book: survey.book, survey: survey).data[:outcome]
      counts[outcome] += 1 if counts.key?(outcome)
    rescue => e
      counts[:errors] += 1
      Rails.logger.error("decide_fixes: book #{id} failed: #{e.class}: #{e.message}")
    end
    Rails.logger.info("decide_fixes batch: #{book_ids.size} books — " + counts.map { |key, count| "#{key} #{count}" }.join(", "))
  end
end
