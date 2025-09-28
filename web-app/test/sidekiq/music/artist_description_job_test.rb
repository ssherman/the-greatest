require "test_helper"

class Music::ArtistDescriptionJobTest < ActiveSupport::TestCase
  def setup
    @artist = music_artists(:pink_floyd)
    @job = Music::ArtistDescriptionJob.new
  end

  test "perform calls ArtistDescriptionTask with correct artist" do
    # Mock the AI task to avoid actual API calls
    mock_task = mock
    mock_result = mock
    mock_result.stubs(:success?).returns(true)
    mock_task.stubs(:call).returns(mock_result)

    Services::Ai::Tasks::ArtistDescriptionTask.expects(:new).with(parent: @artist).returns(mock_task)

    @job.perform(@artist.id)
  end

  test "perform handles task success" do
    mock_task = mock
    mock_result = mock
    mock_result.stubs(:success?).returns(true)
    mock_task.stubs(:call).returns(mock_result)

    Services::Ai::Tasks::ArtistDescriptionTask.stubs(:new).returns(mock_task)
    Rails.logger.expects(:info)

    @job.perform(@artist.id)
  end

  test "perform handles task failure" do
    mock_task = mock
    mock_result = mock
    mock_result.stubs(:success?).returns(false)
    mock_result.stubs(:error).returns("AI service unavailable")
    mock_task.stubs(:call).returns(mock_result)

    Services::Ai::Tasks::ArtistDescriptionTask.stubs(:new).returns(mock_task)
    Rails.logger.expects(:error)

    @job.perform(@artist.id)
  end

  test "perform finds artist by id" do
    Music::Artist.expects(:find).with(@artist.id).returns(@artist)

    # Mock the task to avoid actual execution
    Services::Ai::Tasks::ArtistDescriptionTask.stubs(:new).returns(mock.tap { |m| m.stubs(:call).returns(mock.tap { |r| r.stubs(:success?).returns(true) }) })

    @job.perform(@artist.id)
  end
end
