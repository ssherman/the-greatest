# Writes the re-import report (Services::Books::GoodreadsReimport::Report.call) to
# storage/goodreads_reimport/report-<UTC timestamp>.md and logs the path. Read-only, so it is not behind the re-import
# gate. The report scans every verdict and row, so the rake task only enqueues it.
class Books::GoodreadsReimport::ReportJob
  include Sidekiq::Job

  sidekiq_options queue: :low, retry: 0

  def perform
    path = ::Services::Books::GoodreadsReimport::Report.report_path
    FileUtils.mkdir_p(path.dirname)
    File.write(path, ::Services::Books::GoodreadsReimport::Report.call)
    Rails.logger.info("Goodreads re-import report written to #{path}")
  end
end
