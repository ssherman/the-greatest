require "test_helper"

class Music::Albums::EnrichListItemsJsonJobTest < ActiveSupport::TestCase
  def setup
    @list = lists(:music_albums_list_with_items_json)
  end

  test "perform calls enricher service and logs success" do
    # Mock successful service result
    success_result = {
      success: true,
      message: "Enriched 2 of 2 albums (0 skipped)",
      enriched_count: 2,
      skipped_count: 0,
      total_count: 2
    }

    Services::Lists::Music::Albums::ItemsJsonEnricher.expects(:call)
      .with(list: @list)
      .returns(success_result)

    Rails.logger.expects(:info)

    Music::Albums::EnrichListItemsJsonJob.new.perform(@list.id)
  end

  test "perform calls enricher service and logs failure" do
    # Mock failure result
    failure_result = {
      success: false,
      message: "Test error message",
      enriched_count: 0,
      skipped_count: 0,
      total_count: 0
    }

    Services::Lists::Music::Albums::ItemsJsonEnricher.expects(:call)
      .with(list: @list)
      .returns(failure_result)

    Rails.logger.expects(:error)

    Music::Albums::EnrichListItemsJsonJob.new.perform(@list.id)
  end

  test "perform raises and logs when list not found" do
    Rails.logger.expects(:error)

    error = assert_raises(ActiveRecord::RecordNotFound) do
      Music::Albums::EnrichListItemsJsonJob.new.perform(999999)
    end

    assert_match(/Couldn't find/, error.message)
  end

  test "perform raises and logs on unexpected error" do
    Services::Lists::Music::Albums::ItemsJsonEnricher.expects(:call)
      .raises(StandardError.new("Unexpected error"))

    Rails.logger.expects(:error)

    assert_raises(StandardError) do
      Music::Albums::EnrichListItemsJsonJob.new.perform(@list.id)
    end
  end

  test "job can be enqueued with perform_async" do
    # Use fake mode to test enqueuing without executing
    Sidekiq::Testing.fake! do
      assert_difference "Music::Albums::EnrichListItemsJsonJob.jobs.size", 1 do
        Music::Albums::EnrichListItemsJsonJob.perform_async(@list.id)
      end
    end
  end

  test "job loads correct list by id" do
    # Ensure the service is called with the correct list instance
    Services::Lists::Music::Albums::ItemsJsonEnricher.expects(:call)
      .with { |args| args[:list].id == @list.id }
      .returns(success: true, message: "Test", enriched_count: 0, skipped_count: 0, total_count: 0)

    Rails.logger.stubs(:info)

    Music::Albums::EnrichListItemsJsonJob.new.perform(@list.id)
  end
end
