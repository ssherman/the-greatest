# Runs the independent AI sample check of the re-import (Services::Books::GoodreadsReimport::Report.sample) and
# logs what it found. Read-only, so it is not behind the re-import gate. The rake task only enqueues it: the check
# makes hundreds of AI calls.
class Books::GoodreadsReimport::SampleJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 0

  def perform(n = ::Services::Books::GoodreadsReimport::Report::SAMPLE_ROWS,
    mixed_books = ::Services::Books::GoodreadsReimport::Report::SAMPLE_MIXED_BOOKS)
    Rails.logger.info("Goodreads re-import sample check started: #{n} rows plus #{mixed_books} former mixed books")
    Rails.logger.info("Goodreads re-import sample check:\n" + ::Services::Books::GoodreadsReimport::Report.sample(n: n, mixed_books: mixed_books))
  end
end
