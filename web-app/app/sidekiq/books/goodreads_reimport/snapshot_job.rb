# Records each affected user's list item and review counts before apply (Services::Books::GoodreadsReimport::Report.snapshot)
# in storage/goodreads_reimport/counts.json. Read-only, so it is not behind the re-import gate. It refuses to overwrite
# an existing snapshot unless redo is true: one taken after apply would hide every loss. The rake task only enqueues it.
class Books::GoodreadsReimport::SnapshotJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 0

  # replace is the rake task's "redo".
  def perform(replace = false)
    path = ::Services::Books::GoodreadsReimport::Report.snapshot_path
    count = ::Services::Books::GoodreadsReimport::Report.snapshot(replace: replace)
    if count.nil?
      Rails.logger.warn("Goodreads re-import snapshot: #{path} already exists; left alone (enqueue with redo to replace it)")
    else
      Rails.logger.info("Goodreads re-import snapshot: recorded the counts of #{count} users in #{path}")
    end
  end
end
