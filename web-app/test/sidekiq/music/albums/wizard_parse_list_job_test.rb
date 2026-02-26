require "test_helper"
require "ostruct"

class Music::Albums::WizardParseListJobTest < ActiveSupport::TestCase
  setup do
    @list = lists(:music_albums_list)
    @list.update!(
      raw_content: "<ol><li>Album 1 - Artist 1</li></ol>",
      wizard_state: {"current_step" => 1, "job_status" => "idle"}
    )
  end

  test "job creates list_items from parsed albums" do
    parsed_albums = [
      OpenStruct.new(rank: 1, title: "Album 1", artists: ["Artist 1"], release_year: nil),
      OpenStruct.new(rank: 2, title: "Album 2", artists: ["Artist 2"], release_year: 2020)
    ]

    result = Services::Ai::Result.new(
      success: true,
      data: OpenStruct.new(albums: parsed_albums)
    )

    Services::Ai::Tasks::Lists::Music::AlbumsRawParserTask.any_instance.stubs(:call).returns(result)

    Music::Albums::WizardParseListJob.new.perform(@list.id)

    @list.reload
    assert_equal 2, @list.list_items.unverified.count

    item1 = @list.list_items.find_by(position: 1)
    assert_equal "Album 1", item1.metadata["title"]
    assert_equal ["Artist 1"], item1.metadata["artists"]
    assert_nil item1.listable_id
    assert_not item1.verified
  end

  test "job updates wizard_state to completed on success" do
    parsed_albums = [
      OpenStruct.new(rank: 1, title: "Test", artists: ["Artist"], release_year: nil)
    ]

    result = Services::Ai::Result.new(
      success: true,
      data: OpenStruct.new(albums: parsed_albums)
    )

    Services::Ai::Tasks::Lists::Music::AlbumsRawParserTask.any_instance.stubs(:call).returns(result)

    Music::Albums::WizardParseListJob.new.perform(@list.id)

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

    Services::Ai::Tasks::Lists::Music::AlbumsRawParserTask.any_instance.stubs(:call).returns(result)

    Music::Albums::WizardParseListJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "failed", manager.step_status("parse")
    assert_equal 0, manager.step_progress("parse")
    assert_includes manager.step_error("parse"), "AI service timeout"
  end

  test "job fails immediately if raw_content is blank" do
    @list.update!(raw_content: nil)

    Music::Albums::WizardParseListJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "failed", manager.step_status("parse")
    assert_includes manager.step_error("parse"), "raw_content is blank"
  end

  test "job is idempotent - clears old unverified items" do
    @list.list_items.unverified.destroy_all
    @list.list_items.create!(listable_type: "Music::Album", verified: false, position: 1, metadata: {})
    @list.list_items.create!(listable_type: "Music::Album", verified: false, position: 2, metadata: {})

    parsed_albums = [
      OpenStruct.new(rank: 1, title: "New Album", artists: ["Artist"], release_year: nil)
    ]

    result = Services::Ai::Result.new(
      success: true,
      data: OpenStruct.new(albums: parsed_albums)
    )

    Services::Ai::Tasks::Lists::Music::AlbumsRawParserTask.any_instance.stubs(:call).returns(result)

    Music::Albums::WizardParseListJob.new.perform(@list.id)

    @list.reload
    assert_equal 1, @list.list_items.unverified.count
    assert_equal "New Album", @list.list_items.unverified.first.metadata["title"]
  end

  test "job uses sequential positions when rank is null" do
    parsed_albums = [
      OpenStruct.new(rank: nil, title: "Album A", artists: ["Artist A"], release_year: nil),
      OpenStruct.new(rank: nil, title: "Album B", artists: ["Artist B"], release_year: nil)
    ]

    result = Services::Ai::Result.new(
      success: true,
      data: OpenStruct.new(albums: parsed_albums)
    )

    Services::Ai::Tasks::Lists::Music::AlbumsRawParserTask.any_instance.stubs(:call).returns(result)

    Music::Albums::WizardParseListJob.new.perform(@list.id)

    @list.reload
    positions = @list.list_items.unverified.order(:position).pluck(:position)
    assert_equal [1, 2], positions
  end

  test "job stores all parsed metadata fields correctly" do
    parsed_albums = [
      OpenStruct.new(
        rank: 5,
        title: "The Dark Side of the Moon",
        artists: ["Pink Floyd"],
        release_year: 1973
      )
    ]

    result = Services::Ai::Result.new(
      success: true,
      data: OpenStruct.new(albums: parsed_albums)
    )

    Services::Ai::Tasks::Lists::Music::AlbumsRawParserTask.any_instance.stubs(:call).returns(result)

    Music::Albums::WizardParseListJob.new.perform(@list.id)

    @list.reload
    item = @list.list_items.first
    assert_equal 5, item.metadata["rank"]
    assert_equal "The Dark Side of the Moon", item.metadata["title"]
    assert_equal ["Pink Floyd"], item.metadata["artists"]
    assert_equal 1973, item.metadata["release_year"]
    assert_equal "Music::Album", item.listable_type
    assert_nil item.listable_id
    assert_equal false, item.verified
  end

  test "job raises error when list not found" do
    assert_raises(ActiveRecord::RecordNotFound) do
      Music::Albums::WizardParseListJob.new.perform(999999)
    end
  end
end
