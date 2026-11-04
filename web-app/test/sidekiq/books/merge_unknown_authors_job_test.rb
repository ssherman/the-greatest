# frozen_string_literal: true

require "test_helper"

class Books::MergeUnknownAuthorsJobTest < ActiveSupport::TestCase
  test "runs the merge for real and logs what it did" do
    result = ::Services::Books::Authors::MergeUnknown::Result.new(success?: true, errors: [],
      data: {target_id: 10, target_books: 152, sources: [{id: 11, name: "Anonymous", books: 136}], merged: 1, failed: []})
    ::Services::Books::Authors::MergeUnknown.expects(:call).with(apply: true).returns(result)
    Rails.logger.expects(:info).with { |message| message.include?("merged 1 of 1") }

    Books::MergeUnknownAuthorsJob.new.perform
  end

  test "logs a failure to start without raising" do
    ::Services::Books::Authors::MergeUnknown.expects(:call).with(apply: true)
      .returns(::Services::Books::Authors::MergeUnknown::Result.new(success?: false, data: nil, errors: ["no author named \"Unknown\""]))
    Rails.logger.expects(:warn).with { |message| message.include?("no author named") }

    Books::MergeUnknownAuthorsJob.new.perform
  end
end
