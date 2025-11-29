require "test_helper"
require "ostruct"

class Music::Songs::WizardParseListJobTest < ActiveSupport::TestCase
  setup do
    @list = lists(:music_songs_list)
    @list.update!(
      raw_html: "<ol><li>Song 1 - Artist 1</li></ol>",
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
    assert_equal "completed", @list.wizard_job_status
    assert_equal 100, @list.wizard_job_progress
    assert_equal 1, @list.wizard_job_metadata["total_items"]
    assert @list.wizard_job_metadata["parsed_at"].present?
  end

  test "job updates wizard_state to failed on error" do
    result = Services::Ai::Result.new(
      success: false,
      error: "AI service timeout"
    )

    Services::Ai::Tasks::Lists::Music::SongsRawParserTask.any_instance.stubs(:call).returns(result)

    Music::Songs::WizardParseListJob.new.perform(@list.id)

    @list.reload
    assert_equal "failed", @list.wizard_job_status
    assert_equal 0, @list.wizard_job_progress
    assert_includes @list.wizard_job_error, "AI service timeout"
  end

  test "job fails immediately if raw_html is blank" do
    @list.update!(raw_html: nil)

    Music::Songs::WizardParseListJob.new.perform(@list.id)

    @list.reload
    assert_equal "failed", @list.wizard_job_status
    assert_includes @list.wizard_job_error, "raw_html is blank"
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
end
