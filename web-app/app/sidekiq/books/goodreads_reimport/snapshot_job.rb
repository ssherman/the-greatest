# Records each affected user's list item and review counts before apply (Services::Books::GoodreadsReimport::Report.snapshot)
# in storage/goodreads_reimport/counts.json. Read-only, so it is not behind the re-import gate. It refuses to overwrite
# an existing snapshot unless redo is true (new_pass writes a further file beside it instead): one taken after apply would hide every loss. The rake task only enqueues it.
class Books::GoodreadsReimport::SnapshotJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 0

  # replace is the rake task's "redo"; new_pass is "new_pass": a further counts-<time>.json for a later pass.
  def perform(replace = false, new_pass = false)
    report = ::Services::Books::GoodreadsReimport::Report
    count = report.snapshot(replace: replace, new_pass: new_pass)
    if count.nil? && new_pass
      # Only a file named for this very second refuses a new pass; redo would replace the first pass's counts.json instead.
      Rails.logger.warn("Goodreads re-import snapshot: a counts-<UTC time>.json for this second already exists; " \
        "left alone (enqueue new_pass again)")
    elsif count.nil?
      Rails.logger.warn("Goodreads re-import snapshot: #{report.snapshot_path} already exists; left alone (enqueue with redo to replace it)")
    else
      Rails.logger.info("Goodreads re-import snapshot: recorded the counts of #{count} users in #{report.snapshot_path}")
    end
  end
end
