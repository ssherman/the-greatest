require "test_helper"

class Books::GoodreadsReimport::SampleJobTest < ActiveSupport::TestCase
  test "logs the sample result and is not behind the gate" do
    Rails.configuration.x.goodreads_reimport.stubs(:enabled).returns(false)
    Services::Books::GoodreadsReimport::Report.expects(:sample).with(n: 5, mixed_books: 2).returns("answered no: 0")
    Rails.logger.expects(:info).with { |line| line.include?("started: 5 rows plus 2") }
    Rails.logger.expects(:info).with { |line| line.include?("answered no: 0") }

    Books::GoodreadsReimport::SampleJob.new.perform(5, 2)
  end
end
