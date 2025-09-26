require "test_helper"

class Music::AlbumDescriptionJobTest < ActiveSupport::TestCase
  def setup
    @album = music_albums(:dark_side_of_the_moon)
    @job = Music::AlbumDescriptionJob.new
  end

  test "perform calls AlbumDescriptionTask with correct album" do
    # Mock the AI task to avoid actual API calls
    mock_task = mock
    mock_result = mock
    mock_result.stubs(:success?).returns(true)
    mock_task.stubs(:call).returns(mock_result)

    Services::Ai::Tasks::AlbumDescriptionTask.expects(:new).with(parent: @album).returns(mock_task)

    @job.perform(@album.id)
  end

  test "perform handles task success" do
    mock_task = mock
    mock_result = mock
    mock_result.stubs(:success?).returns(true)
    mock_task.stubs(:call).returns(mock_result)

    Services::Ai::Tasks::AlbumDescriptionTask.stubs(:new).returns(mock_task)
    Rails.logger.expects(:info)

    @job.perform(@album.id)
  end

  test "perform handles task failure" do
    mock_task = mock
    mock_result = mock
    mock_result.stubs(:success?).returns(false)
    mock_result.stubs(:error).returns("AI service unavailable")
    mock_task.stubs(:call).returns(mock_result)

    Services::Ai::Tasks::AlbumDescriptionTask.stubs(:new).returns(mock_task)
    Rails.logger.expects(:error)

    @job.perform(@album.id)
  end

  test "perform finds album by id" do
    Music::Album.expects(:find).with(@album.id).returns(@album)

    # Mock the task to avoid actual execution
    Services::Ai::Tasks::AlbumDescriptionTask.stubs(:new).returns(mock.tap { |m| m.stubs(:call).returns(mock.tap { |r| r.stubs(:success?).returns(true) }) })

    @job.perform(@album.id)
  end
end
