require "test_helper"

class Music::Songs::EnrichListItemsJsonJobTest < ActiveSupport::TestCase
  def setup
    @list = lists(:music_songs_list_with_items_json)
  end

  test "perform calls enricher service and logs success" do
    success_result = {
      success: true,
      message: "Enriched 2 of 2 songs (0 skipped)",
      enriched_count: 2,
      skipped_count: 0,
      total_count: 2
    }

    Services::Lists::Music::Songs::ItemsJsonEnricher.expects(:call)
      .with(list: @list)
      .returns(success_result)

    Music::Songs::EnrichListItemsJsonJob.new.perform(@list.id)
  end

  test "perform calls enricher service and logs failure" do
    failure_result = {
      success: false,
      message: "Test error message",
      enriched_count: 0,
      skipped_count: 0,
      total_count: 0
    }

    Services::Lists::Music::Songs::ItemsJsonEnricher.expects(:call)
      .with(list: @list)
      .returns(failure_result)

    Music::Songs::EnrichListItemsJsonJob.new.perform(@list.id)
  end

  test "perform raises and logs when list not found" do
    error = assert_raises(ActiveRecord::RecordNotFound) do
      Music::Songs::EnrichListItemsJsonJob.new.perform(999999)
    end

    assert_match(/Couldn't find/, error.message)
  end

  test "perform raises and logs on unexpected error" do
    Services::Lists::Music::Songs::ItemsJsonEnricher.expects(:call)
      .raises(StandardError.new("Unexpected error"))

    assert_raises(StandardError) do
      Music::Songs::EnrichListItemsJsonJob.new.perform(@list.id)
    end
  end

  test "job can be enqueued with perform_async" do
    Sidekiq::Testing.fake! do
      assert_difference "Music::Songs::EnrichListItemsJsonJob.jobs.size", 1 do
        Music::Songs::EnrichListItemsJsonJob.perform_async(@list.id)
      end
    end
  end

  test "job loads correct list by id" do
    Services::Lists::Music::Songs::ItemsJsonEnricher.expects(:call)
      .with { |args| args[:list].id == @list.id }
      .returns(success: true, message: "Test", enriched_count: 0, skipped_count: 0, total_count: 0)

    Music::Songs::EnrichListItemsJsonJob.new.perform(@list.id)
  end
end
