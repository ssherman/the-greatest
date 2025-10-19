require "test_helper"

class Music::Albums::ImportListItemsFromJsonJobTest < ActiveSupport::TestCase
  def setup
    @list = lists(:music_albums_list_with_items_json)
  end

  test "perform calls importer service on success" do
    success_result = Services::Lists::Music::Albums::ItemsJsonImporter::Result.new(
      success: true,
      message: "Imported 1 albums",
      imported_count: 1,
      created_directly_count: 0,
      skipped_count: 0,
      error_count: 0,
      data: {}
    )

    Services::Lists::Music::Albums::ItemsJsonImporter.expects(:call)
      .with(list: @list)
      .returns(success_result)

    Music::Albums::ImportListItemsFromJsonJob.new.perform(@list.id)
  end

  test "perform calls importer service on failure" do
    failure_result = Services::Lists::Music::Albums::ItemsJsonImporter::Result.new(
      success: false,
      message: "Import failed",
      imported_count: 0,
      created_directly_count: 0,
      skipped_count: 0,
      error_count: 1,
      data: {errors: ["Test error"]}
    )

    Services::Lists::Music::Albums::ItemsJsonImporter.expects(:call)
      .with(list: @list)
      .returns(failure_result)

    Music::Albums::ImportListItemsFromJsonJob.new.perform(@list.id)
  end

  test "perform raises when list not found" do
    error = assert_raises(ActiveRecord::RecordNotFound) do
      Music::Albums::ImportListItemsFromJsonJob.new.perform(999999)
    end

    assert_match(/Couldn't find/, error.message)
  end

  test "perform raises on unexpected error" do
    Services::Lists::Music::Albums::ItemsJsonImporter.expects(:call)
      .raises(StandardError.new("Unexpected error"))

    assert_raises(StandardError) do
      Music::Albums::ImportListItemsFromJsonJob.new.perform(@list.id)
    end
  end

  test "job can be enqueued with perform_async" do
    Sidekiq::Testing.fake! do
      assert_difference "Music::Albums::ImportListItemsFromJsonJob.jobs.size", 1 do
        Music::Albums::ImportListItemsFromJsonJob.perform_async(@list.id)
      end
    end
  end

  test "job loads correct list by id" do
    success_result = Services::Lists::Music::Albums::ItemsJsonImporter::Result.new(
      success: true,
      message: "Test",
      imported_count: 0,
      created_directly_count: 0,
      skipped_count: 0,
      error_count: 0,
      data: {}
    )

    Services::Lists::Music::Albums::ItemsJsonImporter.expects(:call)
      .with { |args| args[:list].id == @list.id }
      .returns(success_result)

    Music::Albums::ImportListItemsFromJsonJob.new.perform(@list.id)
  end
end
