require "test_helper"

class Books::GoodreadsRebuild::SurveyJobTest < ActiveSupport::TestCase
  def result(stopped: false, error: nil)
    Struct.new(:success?, :data, :errors, keyword_init: true)
      .new(success?: !stopped, data: {processed: 3, stopped: stopped, error: error}, errors: [error].compact)
  end

  test "perform runs the survey" do
    Services::Books::GoodreadsRebuild::Survey.expects(:call).with(limit: 50, resurvey: false).returns(result)

    Books::GoodreadsRebuild::SurveyJob.new.perform(50)
  end

  test "perform passes resurvey" do
    Services::Books::GoodreadsRebuild::Survey.expects(:call).with(limit: nil, resurvey: true).returns(result)

    Books::GoodreadsRebuild::SurveyJob.new.perform(nil, true)
  end
end
