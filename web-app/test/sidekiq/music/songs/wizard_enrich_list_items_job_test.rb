require "test_helper"

class Music::Songs::WizardEnrichListItemsJobTest < ActiveSupport::TestCase
  setup do
    @list = lists(:music_songs_list)
    @list.update!(wizard_state: {"current_step" => 2, "job_status" => "idle"})

    @list.list_items.unverified.destroy_all

    @list_items = []
    3.times do |i|
      @list_items << ListItem.create!(
        list: @list,
        listable_type: "Music::Song",
        listable_id: nil,
        verified: false,
        position: i + 1,
        metadata: {
          "title" => "Song #{i + 1}",
          "artists" => ["Artist #{i + 1}"]
        }
      )
    end
  end

  teardown do
    @list_items&.each(&:destroy)
  end

  test "job updates wizard_state to running at start" do
    Services::Lists::Music::Songs::ListItemEnricher.stubs(:call).returns({success: false, source: :not_found, data: {}})

    Music::Songs::WizardEnrichListItemsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_includes ["running", "completed"], manager.step_status("enrich")
  end

  test "job enriches all unverified items" do
    enricher_mock = mock
    enricher_mock.stubs(:call).returns({success: false, source: :not_found, data: {}})

    Services::Lists::Music::Songs::ListItemEnricher.expects(:call).times(3).returns({success: false, source: :not_found, data: {}})

    Music::Songs::WizardEnrichListItemsJob.new.perform(@list.id)
  end

  test "job updates wizard_state to completed with final stats" do
    Services::Lists::Music::Songs::ListItemEnricher.stubs(:call).returns({success: true, source: :opensearch, data: {}})

    Music::Songs::WizardEnrichListItemsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "completed", manager.step_status("enrich")
    assert_equal 100, manager.step_progress("enrich")
    assert_equal 3, manager.step_metadata("enrich")["total_items"]
    assert_equal 3, manager.step_metadata("enrich")["processed_items"]
    assert_equal 3, manager.step_metadata("enrich")["opensearch_matches"]
    assert manager.step_metadata("enrich")["enriched_at"].present?
  end

  test "job updates wizard_state to failed on critical error" do
    # Simulate a failure in the outer job workflow (not individual item enrichment)
    # by having the progress update fail
    Services::Lists::Music::Songs::ListItemEnricher.stubs(:call).returns({success: false, source: :not_found, data: {}})

    # Simulate an error after enrichment completes but before final update
    # Job uses wizard_manager.update_step_status! which calls list.update!
    Music::Songs::List.any_instance.stubs(:update!).raises(StandardError.new("Database connection error")).then.returns(true)

    assert_raises(StandardError) do
      Music::Songs::WizardEnrichListItemsJob.new.perform(@list.id)
    end
  end

  test "job is idempotent - clears previous enrichment data" do
    @list_items.first.update!(
      listable_id: 999,
      metadata: {
        "title" => "Song 1",
        "artists" => ["Artist 1"],
        "song_id" => 999,
        "opensearch_match" => true
      }
    )

    Services::Lists::Music::Songs::ListItemEnricher.stubs(:call).returns({success: false, source: :not_found, data: {}})

    Music::Songs::WizardEnrichListItemsJob.new.perform(@list.id)

    @list_items.first.reload
    assert_nil @list_items.first.listable_id
    assert_nil @list_items.first.metadata["song_id"]
    assert_nil @list_items.first.metadata["opensearch_match"]
    assert_equal "Song 1", @list_items.first.metadata["title"]
  end

  test "job handles empty list gracefully" do
    @list_items.each(&:destroy)
    @list_items.clear

    Music::Songs::WizardEnrichListItemsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "failed", manager.step_status("enrich")
    assert_includes manager.step_error("enrich"), "No items to enrich"
  end

  test "job continues processing after individual item failure" do
    call_count = 0
    Services::Lists::Music::Songs::ListItemEnricher.stubs(:call).with do |args|
      call_count += 1
      if call_count == 2
        raise StandardError, "Single item error"
      end
      true
    end.returns({success: true, source: :opensearch, data: {}})

    Music::Songs::WizardEnrichListItemsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "completed", manager.step_status("enrich")
    assert_equal 2, manager.step_metadata("enrich")["opensearch_matches"]
    assert_equal 1, manager.step_metadata("enrich")["not_found"]
  end

  test "job tracks opensearch vs musicbrainz match counts" do
    responses = [
      {success: true, source: :opensearch, data: {}},
      {success: true, source: :musicbrainz, data: {}},
      {success: false, source: :not_found, data: {}}
    ]

    Services::Lists::Music::Songs::ListItemEnricher.stubs(:call).returns(*responses)

    Music::Songs::WizardEnrichListItemsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal 1, manager.step_metadata("enrich")["opensearch_matches"]
    assert_equal 1, manager.step_metadata("enrich")["musicbrainz_matches"]
    assert_equal 1, manager.step_metadata("enrich")["not_found"]
  end

  test "job raises error when list not found" do
    assert_raises(ActiveRecord::RecordNotFound) do
      Music::Songs::WizardEnrichListItemsJob.new.perform(999999)
    end
  end

  test "job preserves verified items" do
    verified_item = ListItem.create!(
      list: @list,
      listable_type: "Music::Song",
      listable_id: music_songs(:time).id,
      verified: true,
      position: 10,
      metadata: {"title" => "Verified Song", "artists" => ["Artist"]}
    )

    Services::Lists::Music::Songs::ListItemEnricher.stubs(:call).returns({success: false, source: :not_found, data: {}})

    Music::Songs::WizardEnrichListItemsJob.new.perform(@list.id)

    verified_item.reload
    assert verified_item.verified
    assert_equal music_songs(:time).id, verified_item.listable_id

    verified_item.destroy
  end
end
