require "test_helper"
require "ostruct"

class Music::Songs::WizardParseListJobTest < ActiveSupport::TestCase
  setup do
    @list = lists(:music_songs_list)
    @list.update!(
      raw_content: "<ol><li>Song 1 - Artist 1</li></ol>",
      wizard_state: {"current_step" => 1, "job_status" => "idle"}
    )
  end

  test "job creates list_items from parsed songs" do
    parsed_songs = [
      OpenStruct.new(rank: 1, title: "Song 1", artists: ["Artist 1"], album: nil, release_year: nil),
      OpenStruct.new(rank: 2, title: "Song 2", artists: ["Artist 2"], album: "Album 2", release_year: 2020)
    ]

    result = Services::Ai::Result.new(
      success: true,
      data: OpenStruct.new(songs: parsed_songs)
    )

    Services::Ai::Tasks::Lists::Music::SongsRawParserTask.any_instance.stubs(:call).returns(result)

    Music::Songs::WizardParseListJob.new.perform(@list.id)

    @list.reload
    assert_equal 2, @list.list_items.unverified.count

    item1 = @list.list_items.find_by(position: 1)
    assert_equal "Song 1", item1.metadata["title"]
    assert_equal ["Artist 1"], item1.metadata["artists"]
    assert_nil item1.listable_id
    assert_not item1.verified
  end

  test "job updates wizard_state to completed on success" do
    parsed_songs = [
      OpenStruct.new(rank: 1, title: "Test", artists: ["Artist"], album: nil, release_year: nil)
    ]

    result = Services::Ai::Result.new(
      success: true,
      data: OpenStruct.new(songs: parsed_songs)
    )

    Services::Ai::Tasks::Lists::Music::SongsRawParserTask.any_instance.stubs(:call).returns(result)

    Music::Songs::WizardParseListJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "completed", manager.step_status("parse")
    assert_equal 100, manager.step_progress("parse")
    assert_equal 1, manager.step_metadata("parse")["total_items"]
    assert manager.step_metadata("parse")["parsed_at"].present?
  end

  test "job updates wizard_state to failed on error" do
    result = Services::Ai::Result.new(
      success: false,
      error: "AI service timeout"
    )

    Services::Ai::Tasks::Lists::Music::SongsRawParserTask.any_instance.stubs(:call).returns(result)

    Music::Songs::WizardParseListJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "failed", manager.step_status("parse")
    assert_equal 0, manager.step_progress("parse")
    assert_includes manager.step_error("parse"), "AI service timeout"
  end

  test "job fails immediately if raw_content is blank" do
    @list.update!(raw_content: nil)

    Music::Songs::WizardParseListJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "failed", manager.step_status("parse")
    assert_includes manager.step_error("parse"), "raw_content is blank"
  end

  test "job is idempotent - clears old unverified items" do
    @list.list_items.unverified.destroy_all
    @list.list_items.create!(listable_type: "Music::Song", verified: false, position: 1, metadata: {})
    @list.list_items.create!(listable_type: "Music::Song", verified: false, position: 2, metadata: {})

    parsed_songs = [
      OpenStruct.new(rank: 1, title: "New Song", artists: ["Artist"], album: nil, release_year: nil)
    ]

    result = Services::Ai::Result.new(
      success: true,
      data: OpenStruct.new(songs: parsed_songs)
    )

    Services::Ai::Tasks::Lists::Music::SongsRawParserTask.any_instance.stubs(:call).returns(result)

    Music::Songs::WizardParseListJob.new.perform(@list.id)

    @list.reload
    assert_equal 1, @list.list_items.unverified.count
    assert_equal "New Song", @list.list_items.unverified.first.metadata["title"]
  end

  test "job uses sequential positions when rank is null" do
    parsed_songs = [
      OpenStruct.new(rank: nil, title: "Song A", artists: ["Artist A"], album: nil, release_year: nil),
      OpenStruct.new(rank: nil, title: "Song B", artists: ["Artist B"], album: nil, release_year: nil)
    ]

    result = Services::Ai::Result.new(
      success: true,
      data: OpenStruct.new(songs: parsed_songs)
    )

    Services::Ai::Tasks::Lists::Music::SongsRawParserTask.any_instance.stubs(:call).returns(result)

    Music::Songs::WizardParseListJob.new.perform(@list.id)

    @list.reload
    positions = @list.list_items.unverified.order(:position).pluck(:position)
    assert_equal [1, 2], positions
  end

  test "job stores all parsed metadata fields correctly" do
    parsed_songs = [
      OpenStruct.new(
        rank: 5,
        title: "Bohemian Rhapsody",
        artists: ["Queen"],
        album: "A Night at the Opera",
        release_year: 1975
      )
    ]

    result = Services::Ai::Result.new(
      success: true,
      data: OpenStruct.new(songs: parsed_songs)
    )

    Services::Ai::Tasks::Lists::Music::SongsRawParserTask.any_instance.stubs(:call).returns(result)

    Music::Songs::WizardParseListJob.new.perform(@list.id)

    @list.reload
    item = @list.list_items.first
    assert_equal 5, item.metadata["rank"]
    assert_equal "Bohemian Rhapsody", item.metadata["title"]
    assert_equal ["Queen"], item.metadata["artists"]
    assert_equal "A Night at the Opera", item.metadata["album"]
    assert_equal 1975, item.metadata["release_year"]
    assert_equal "Music::Song", item.listable_type
    assert_nil item.listable_id
    assert_equal false, item.verified
  end

  test "job raises error when list not found" do
    assert_raises(ActiveRecord::RecordNotFound) do
      Music::Songs::WizardParseListJob.new.perform(999999)
    end
  end

  # Batch mode tests

  test "batch mode creates items with strictly sequential positions" do
    # Enable batch mode and set up plain text content
    @list.update!(
      wizard_state: {"current_step" => 1, "batch_mode" => true},
      simplified_content: "1. Song A - Artist A\n2. Song B - Artist B\n3. Song C - Artist C"
    )

    # Mock AI returns items with rank: 5, 10, 15 - but batch mode should ignore these
    parsed_songs = [
      OpenStruct.new(rank: 5, title: "Song A", artists: ["Artist A"], album: nil, release_year: nil),
      OpenStruct.new(rank: 10, title: "Song B", artists: ["Artist B"], album: nil, release_year: nil),
      OpenStruct.new(rank: 15, title: "Song C", artists: ["Artist C"], album: nil, release_year: nil)
    ]

    result = Services::Ai::Result.new(
      success: true,
      data: OpenStruct.new(songs: parsed_songs)
    )

    Services::Ai::Tasks::Lists::Music::SongsRawParserTask.any_instance.stubs(:call).returns(result)

    Music::Songs::WizardParseListJob.new.perform(@list.id)

    @list.reload
    positions = @list.list_items.unverified.order(:position).pluck(:position)
    # Batch mode uses sequential positions, ignoring AI-extracted ranks
    assert_equal [1, 2, 3], positions
  end

  test "batch mode processes multiple batches and creates all items" do
    # Create 150 lines of content (will create 2 batches of 100 and 50)
    lines = (1..150).map { |i| "#{i}. Song #{i} - Artist #{i}" }
    @list.update!(
      wizard_state: {"current_step" => 1, "batch_mode" => true},
      simplified_content: lines.join("\n")
    )

    # First batch returns 100 items
    songs_batch1 = (1..100).map do |i|
      OpenStruct.new(rank: nil, title: "Song #{i}", artists: ["Artist #{i}"], album: nil, release_year: nil)
    end
    result1 = Services::Ai::Result.new(success: true, data: OpenStruct.new(songs: songs_batch1))

    # Second batch returns 50 items
    songs_batch2 = (1..50).map do |i|
      OpenStruct.new(rank: nil, title: "Song #{i}", artists: ["Artist #{i}"], album: nil, release_year: nil)
    end
    result2 = Services::Ai::Result.new(success: true, data: OpenStruct.new(songs: songs_batch2))

    # Use multiple_yields alternative - sequence of returns
    Services::Ai::Tasks::Lists::Music::SongsRawParserTask.any_instance.stubs(:call).returns(result1).then.returns(result2)

    Music::Songs::WizardParseListJob.new.perform(@list.id)

    @list.reload
    assert_equal 150, @list.list_items.unverified.count

    # Verify positions are cumulative across batches
    positions = @list.list_items.unverified.order(:position).pluck(:position)
    assert_equal (1..150).to_a, positions
  end

  test "batch mode metadata includes batch info on completion" do
    @list.update!(
      wizard_state: {"current_step" => 1, "batch_mode" => true},
      simplified_content: "1. Song A - Artist A\n2. Song B - Artist B"
    )

    parsed_songs = [
      OpenStruct.new(rank: nil, title: "Song A", artists: ["Artist A"], album: nil, release_year: nil),
      OpenStruct.new(rank: nil, title: "Song B", artists: ["Artist B"], album: nil, release_year: nil)
    ]

    result = Services::Ai::Result.new(
      success: true,
      data: OpenStruct.new(songs: parsed_songs)
    )

    Services::Ai::Tasks::Lists::Music::SongsRawParserTask.any_instance.stubs(:call).returns(result)

    Music::Songs::WizardParseListJob.new.perform(@list.id)

    @list.reload
    metadata = @list.wizard_manager.step_metadata("parse")
    assert_equal true, metadata["batched"]
    assert_equal 1, metadata["total_batches"]
    assert_equal 2, metadata["total_items"]
  end

  test "batch mode filters empty lines before batching" do
    @list.update!(
      wizard_state: {"current_step" => 1, "batch_mode" => true},
      simplified_content: "1. Song A - Artist A\n\n\n2. Song B - Artist B\n   \n3. Song C - Artist C"
    )

    # Should only get 3 non-empty lines
    parsed_songs = [
      OpenStruct.new(rank: nil, title: "Song A", artists: ["Artist A"], album: nil, release_year: nil),
      OpenStruct.new(rank: nil, title: "Song B", artists: ["Artist B"], album: nil, release_year: nil),
      OpenStruct.new(rank: nil, title: "Song C", artists: ["Artist C"], album: nil, release_year: nil)
    ]

    result = Services::Ai::Result.new(
      success: true,
      data: OpenStruct.new(songs: parsed_songs)
    )

    Services::Ai::Tasks::Lists::Music::SongsRawParserTask.any_instance.stubs(:call).returns(result)

    Music::Songs::WizardParseListJob.new.perform(@list.id)

    @list.reload
    assert_equal 3, @list.list_items.unverified.count
  end

  test "batch mode fails entire step if any batch fails" do
    lines = (1..150).map { |i| "#{i}. Song #{i} - Artist #{i}" }
    @list.update!(
      wizard_state: {"current_step" => 1, "batch_mode" => true},
      simplified_content: lines.join("\n")
    )

    # First batch succeeds
    songs_batch1 = (1..100).map do |i|
      OpenStruct.new(rank: nil, title: "Song #{i}", artists: ["Artist #{i}"], album: nil, release_year: nil)
    end
    result1 = Services::Ai::Result.new(success: true, data: OpenStruct.new(songs: songs_batch1))

    # Second batch fails
    result2 = Services::Ai::Result.new(success: false, error: "AI timeout")

    Services::Ai::Tasks::Lists::Music::SongsRawParserTask.any_instance.stubs(:call).returns(result1).then.returns(result2)

    assert_raises(RuntimeError) do
      Music::Songs::WizardParseListJob.new.perform(@list.id)
    end

    @list.reload
    manager = @list.wizard_manager
    assert_equal "failed", manager.step_status("parse")
    assert_includes manager.step_error("parse"), "batch 2"
  end

  test "batch mode off still uses AI-extracted ranks" do
    # batch_mode not set (defaults to false)
    @list.update!(
      wizard_state: {"current_step" => 1},
      simplified_content: "Some HTML content"
    )

    # AI returns items with explicit ranks
    parsed_songs = [
      OpenStruct.new(rank: 5, title: "Song A", artists: ["Artist A"], album: nil, release_year: nil),
      OpenStruct.new(rank: 10, title: "Song B", artists: ["Artist B"], album: nil, release_year: nil)
    ]

    result = Services::Ai::Result.new(
      success: true,
      data: OpenStruct.new(songs: parsed_songs)
    )

    Services::Ai::Tasks::Lists::Music::SongsRawParserTask.any_instance.stubs(:call).returns(result)

    Music::Songs::WizardParseListJob.new.perform(@list.id)

    @list.reload
    positions = @list.list_items.unverified.order(:position).pluck(:position)
    # Non-batch mode uses AI-extracted ranks
    assert_equal [5, 10], positions
  end
end
