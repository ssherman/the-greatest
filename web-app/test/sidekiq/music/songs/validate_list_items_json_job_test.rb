require "test_helper"

class Music::Songs::ValidateListItemsJsonJobTest < ActiveSupport::TestCase
  def setup
    @list = lists(:music_songs_list_with_items_json)
  end

  test "perform calls validator task on success" do
    success_result = Services::Ai::Result.new(
      success: true,
      data: {
        valid_count: 5,
        invalid_count: 2,
        total_count: 7,
        reasoning: "Found 2 invalid matches"
      }
    )

    mock_task = mock
    mock_task.expects(:call).returns(success_result)

    Services::Ai::Tasks::Lists::Music::Songs::ItemsJsonValidatorTask.expects(:new)
      .with(parent: @list)
      .returns(mock_task)

    Music::Songs::ValidateListItemsJsonJob.new.perform(@list.id)
  end

  test "perform calls validator task on failure" do
    failure_result = Services::Ai::Result.new(
      success: false,
      error: "AI service unavailable"
    )

    mock_task = mock
    mock_task.expects(:call).returns(failure_result)

    Services::Ai::Tasks::Lists::Music::Songs::ItemsJsonValidatorTask.expects(:new)
      .with(parent: @list)
      .returns(mock_task)

    Music::Songs::ValidateListItemsJsonJob.new.perform(@list.id)
  end

  test "perform raises when list not found" do
    error = assert_raises(ActiveRecord::RecordNotFound) do
      Music::Songs::ValidateListItemsJsonJob.new.perform(999999)
    end

    assert_match(/Couldn't find/, error.message)
  end

  test "perform raises on unexpected error" do
    Services::Ai::Tasks::Lists::Music::Songs::ItemsJsonValidatorTask.expects(:new)
      .raises(StandardError.new("Unexpected error"))

    assert_raises(StandardError) do
      Music::Songs::ValidateListItemsJsonJob.new.perform(@list.id)
    end
  end

  test "job can be enqueued with perform_async" do
    Sidekiq::Testing.fake! do
      assert_difference "Music::Songs::ValidateListItemsJsonJob.jobs.size", 1 do
        Music::Songs::ValidateListItemsJsonJob.perform_async(@list.id)
      end
    end
  end

  test "job loads correct list by id" do
    success_result = Services::Ai::Result.new(
      success: true,
      data: {valid_count: 0, invalid_count: 0, total_count: 0}
    )

    mock_task = mock
    mock_task.stubs(:call).returns(success_result)

    Services::Ai::Tasks::Lists::Music::Songs::ItemsJsonValidatorTask.expects(:new)
      .with { |args| args[:parent].id == @list.id }
      .returns(mock_task)

    Music::Songs::ValidateListItemsJsonJob.new.perform(@list.id)
  end
end
