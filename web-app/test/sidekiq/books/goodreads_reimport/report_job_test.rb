require "test_helper"

class Books::GoodreadsReimport::ReportJobTest < ActiveSupport::TestCase
  test "writes the report under the storage directory with the gate off and logs the path" do
    dir = Pathname.new(Dir.mktmpdir)
    path = dir.join("nested", "report-20261103T000000Z.md")
    Rails.configuration.x.goodreads_reimport.stubs(:enabled).returns(false)
    Services::Books::GoodreadsReimport::Report.stubs(:report_path).returns(path)
    Services::Books::GoodreadsReimport::Report.expects(:call).returns("THE REPORT")
    Rails.logger.expects(:info).with { |line| line.include?(path.to_s) }

    Books::GoodreadsReimport::ReportJob.new.perform

    assert_equal "THE REPORT", path.read
  end

  test "report_path is timestamped under storage/goodreads_reimport" do
    path = Services::Books::GoodreadsReimport::Report.report_path(Time.utc(2026, 11, 3, 4, 5, 6))

    assert_equal Rails.root.join("storage/goodreads_reimport/report-20261103T040506Z.md"), path
  end
end
