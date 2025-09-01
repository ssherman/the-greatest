require "test_helper"

class ParseListWithAiJobTest < ActiveSupport::TestCase
  def test_calls_parse_with_ai_on_correct_list
    # Create a mock list object
    list = mock("list")
    list.stubs(:id).returns(123)
    list.stubs(:name).returns("Test List")

    # Mock the parse_with_ai! method to return success
    list.expects(:parse_with_ai!).returns({success: true})

    # Mock List.find to return our mock list
    List.expects(:find).with(123).returns(list)

    # Perform the job
    ParseListWithAiJob.new.perform(123)
  end

  def test_handles_parse_failure_gracefully
    # Create a mock list object
    list = mock("list")
    list.stubs(:id).returns(123)
    list.stubs(:name).returns("Test List")

    # Mock the parse_with_ai! method to return failure
    list.expects(:parse_with_ai!).returns({success: false, error: "Test error"})

    # Mock List.find to return our mock list
    List.expects(:find).with(123).returns(list)

    # Should not raise an exception
    ParseListWithAiJob.new.perform(123)
  end

  def test_raises_exception_when_list_not_found
    # Mock List.find to raise ActiveRecord::RecordNotFound
    List.expects(:find).with(999).raises(ActiveRecord::RecordNotFound)

    # Should re-raise the exception
    assert_raises(ActiveRecord::RecordNotFound) do
      ParseListWithAiJob.new.perform(999)
    end
  end
end
