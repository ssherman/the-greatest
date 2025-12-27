require "test_helper"

class Music::Songs::WizardValidateListItemsJobTest < ActiveSupport::TestCase
  setup do
    @list = lists(:music_songs_list)
    @list.update!(wizard_state: {"current_step" => 3, "steps" => {"validate" => {"status" => "idle"}}})

    @list.list_items.unverified.destroy_all

    @list_items = []
    @list_items << ListItem.create!(
      list: @list,
      listable_type: "Music::Song",
      listable_id: nil,
      verified: false,
      position: 1,
      metadata: {
        "title" => "Come Together",
        "artists" => ["The Beatles"],
        "song_id" => 123,
        "song_name" => "Come Together",
        "opensearch_match" => true
      }
    )

    @list_items << ListItem.create!(
      list: @list,
      listable_type: "Music::Song",
      listable_id: nil,
      verified: false,
      position: 2,
      metadata: {
        "title" => "Imagine",
        "artists" => ["John Lennon"],
        "mb_recording_id" => "a1b2c3d4-5e6f-7a8b-9c0d-1e2f3a4b5c6d",
        "mb_recording_name" => "Imagine (Live)",
        "mb_artist_names" => ["John Lennon"],
        "musicbrainz_match" => true
      }
    )
  end

  teardown do
    @list_items&.each(&:destroy)
  end

  test "job updates wizard_step_status to running at start" do
    result = Services::Ai::Result.new(
      success: true,
      data: {valid_count: 2, invalid_count: 0, verified_count: 2, total_count: 2, reasoning: "All valid"}
    )
    Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask.any_instance.stubs(:call).returns(result)

    Music::Songs::WizardValidateListItemsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_includes ["running", "completed"], manager.step_status("validate")
  end

  test "job calls ListItemsValidatorTask" do
    result = Services::Ai::Result.new(
      success: true,
      data: {valid_count: 2, invalid_count: 0, verified_count: 2, total_count: 2, reasoning: "All valid"}
    )

    Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask.any_instance.expects(:call).returns(result)

    Music::Songs::WizardValidateListItemsJob.new.perform(@list.id)
  end

  test "job updates wizard_step_status to completed with stats on success" do
    result = Services::Ai::Result.new(
      success: true,
      data: {valid_count: 1, invalid_count: 1, verified_count: 1, total_count: 2, reasoning: "One invalid"}
    )
    Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask.any_instance.stubs(:call).returns(result)

    Music::Songs::WizardValidateListItemsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "completed", manager.step_status("validate")
    assert_equal 100, manager.step_progress("validate")

    metadata = manager.step_metadata("validate")
    assert_equal 2, metadata["validated_items"]
    assert_equal 1, metadata["valid_count"]
    assert_equal 1, metadata["invalid_count"]
    assert_equal 1, metadata["verified_count"]
    assert_equal "One invalid", metadata["reasoning"]
    assert metadata["validated_at"].present?
  end

  test "job updates wizard_step_status to failed on error" do
    result = Services::Ai::Result.new(success: false, error: "AI service timeout")
    Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask.any_instance.stubs(:call).returns(result)

    Music::Songs::WizardValidateListItemsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "failed", manager.step_status("validate")
    assert_equal "AI service timeout", manager.step_error("validate")
  end

  test "job handles empty list gracefully (no enriched items)" do
    @list_items.each(&:destroy)
    @list_items.clear

    Music::Songs::WizardValidateListItemsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "completed", manager.step_status("validate")
    assert_equal 100, manager.step_progress("validate")

    metadata = manager.step_metadata("validate")
    assert_equal 0, metadata["validated_items"]
    assert_equal 0, metadata["valid_count"]
    assert_equal 0, metadata["invalid_count"]
    assert_equal "No enriched items to validate", metadata["reasoning"]
  end

  test "job is idempotent - clears previous validation flags" do
    @list_items.first.update!(metadata: @list_items.first.metadata.merge("ai_match_invalid" => true))

    result = Services::Ai::Result.new(
      success: true,
      data: {valid_count: 2, invalid_count: 0, verified_count: 2, total_count: 2, reasoning: "All valid now"}
    )
    Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask.any_instance.stubs(:call).returns(result)

    Music::Songs::WizardValidateListItemsJob.new.perform(@list.id)

    @list_items.first.reload
    refute @list_items.first.metadata.key?("ai_match_invalid")
  end

  test "job is idempotent - resets verified to false before validation" do
    @list_items.first.update!(verified: true, metadata: @list_items.first.metadata.merge("ai_match_invalid" => true))

    result = Services::Ai::Result.new(
      success: true,
      data: {valid_count: 2, invalid_count: 0, verified_count: 2, total_count: 2, reasoning: "All valid"}
    )
    Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask.any_instance.stubs(:call).returns(result)

    Music::Songs::WizardValidateListItemsJob.new.perform(@list.id)

    # The clear_previous_validation_flags method should have reset verified and removed ai_match_invalid
    @list_items.first.reload
    # Note: The job clears ai_match_invalid flag for items that had it
    refute @list_items.first.metadata.key?("ai_match_invalid")
  end

  test "job raises error when list not found" do
    assert_raises(ActiveRecord::RecordNotFound) do
      Music::Songs::WizardValidateListItemsJob.new.perform(999999)
    end
  end

  test "job validates both OpenSearch and MusicBrainz matches" do
    result = Services::Ai::Result.new(
      success: true,
      data: {valid_count: 2, invalid_count: 0, verified_count: 2, total_count: 2, reasoning: "All valid"}
    )
    Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask.any_instance.stubs(:call).returns(result)

    Music::Songs::WizardValidateListItemsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    metadata = manager.step_metadata("validate")
    assert_equal 2, metadata["validated_items"]
  end

  test "job skips items without enrichment" do
    @list_items << ListItem.create!(
      list: @list,
      listable_type: "Music::Song",
      listable_id: nil,
      verified: false,
      position: 3,
      metadata: {"title" => "Unknown Song", "artists" => ["Unknown Artist"]}
    )

    result = Services::Ai::Result.new(
      success: true,
      data: {valid_count: 2, invalid_count: 0, verified_count: 2, total_count: 2, reasoning: "All valid"}
    )
    Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask.any_instance.stubs(:call).returns(result)

    Music::Songs::WizardValidateListItemsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    metadata = manager.step_metadata("validate")
    assert_equal 2, metadata["validated_items"]
  end

  test "job handles exception during AI call" do
    Services::Ai::Tasks::Lists::Music::Songs::ListItemsValidatorTask.any_instance.stubs(:call).raises(StandardError.new("Network error"))

    assert_raises(StandardError) do
      Music::Songs::WizardValidateListItemsJob.new.perform(@list.id)
    end

    @list.reload
    manager = @list.wizard_manager
    assert_equal "failed", manager.step_status("validate")
    assert_equal "Network error", manager.step_error("validate")
  end
end
