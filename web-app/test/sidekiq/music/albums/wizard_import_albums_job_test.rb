require "test_helper"

class Music::Albums::WizardImportAlbumsJobTest < ActiveSupport::TestCase
  setup do
    @list = lists(:music_albums_list)
    @list.update!(wizard_state: {"current_step" => 5, "import_source" => "custom_html"})

    @list.list_items.destroy_all

    @albums = [music_albums(:dark_side_of_the_moon), music_albums(:wish_you_were_here), music_albums(:animals)]

    @list_items = []
    3.times do |i|
      @list_items << ListItem.create!(
        list: @list,
        listable_type: "Music::Album",
        listable_id: nil,
        verified: false,
        position: i + 1,
        metadata: {
          "title" => "Album #{i + 1}",
          "artists" => ["Artist #{i + 1}"],
          "mb_release_group_id" => "mb-release-group-#{i + 1}"
        }
      )
    end
  end

  teardown do
    @list_items&.each { |item| item.destroy if item.persisted? }
  end

  test "job updates wizard_step_status to running at start" do
    mock_importer_success_sequential

    Music::Albums::WizardImportAlbumsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_includes ["running", "completed"], manager.step_status("import")
  end

  test "job dispatches based on import_source in wizard_state" do
    @list.update!(wizard_state: {"import_source" => "musicbrainz_series"})

    # Series import falls back to custom_html logic for now
    mock_importer_success_sequential

    Music::Albums::WizardImportAlbumsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "completed", manager.step_status("import")
  end

  test "job raises error when list not found" do
    assert_raises(ActiveRecord::RecordNotFound) do
      Music::Albums::WizardImportAlbumsJob.new.perform(999999)
    end
  end

  test "custom_html: processes only items with mb_release_group_id and no listable_id" do
    item_without_mb_id = ListItem.create!(
      list: @list,
      listable_type: "Music::Album",
      listable_id: nil,
      verified: false,
      position: 10,
      metadata: {"title" => "No MB ID Album"}
    )

    DataImporters::Music::Album::Importer.expects(:call).times(3).returns(
      mock_importer_result(true, @albums[0]),
      mock_importer_result(true, @albums[1]),
      mock_importer_result(true, @albums[2])
    )

    Music::Albums::WizardImportAlbumsJob.new.perform(@list.id)

    item_without_mb_id.destroy
  end

  test "custom_html: calls DataImporters::Music::Album::Importer for each item" do
    DataImporters::Music::Album::Importer.expects(:call)
      .with(release_group_musicbrainz_id: "mb-release-group-1")
      .returns(mock_importer_result(true, @albums[0]))
    DataImporters::Music::Album::Importer.expects(:call)
      .with(release_group_musicbrainz_id: "mb-release-group-2")
      .returns(mock_importer_result(true, @albums[1]))
    DataImporters::Music::Album::Importer.expects(:call)
      .with(release_group_musicbrainz_id: "mb-release-group-3")
      .returns(mock_importer_result(true, @albums[2]))

    Music::Albums::WizardImportAlbumsJob.new.perform(@list.id)
  end

  test "custom_html: sets listable_id on successful import" do
    mock_importer_success_sequential

    Music::Albums::WizardImportAlbumsJob.new.perform(@list.id)

    @list_items.each_with_index do |item, i|
      item.reload
      assert_equal @albums[i].id, item.listable_id
    end
  end

  test "custom_html: sets verified to true on successful import" do
    mock_importer_success_sequential

    Music::Albums::WizardImportAlbumsJob.new.perform(@list.id)

    @list_items.each do |item|
      item.reload
      assert item.verified
    end
  end

  test "custom_html: stores import timestamp in metadata" do
    mock_importer_success_sequential

    Music::Albums::WizardImportAlbumsJob.new.perform(@list.id)

    @list_items.each do |item|
      item.reload
      assert item.metadata["imported_at"].present?
      assert item.metadata["imported_album_id"].present?
    end
  end

  test "custom_html: stores import error on failure" do
    DataImporters::Music::Album::Importer.stubs(:call).returns(mock_importer_result(false))

    Music::Albums::WizardImportAlbumsJob.new.perform(@list.id)

    @list_items.each do |item|
      item.reload
      assert item.metadata["import_error"].present?
      assert item.metadata["import_attempted_at"].present?
    end
  end

  test "custom_html: continues after individual item failure" do
    DataImporters::Music::Album::Importer.stubs(:call).returns(
      mock_importer_result(true, @albums[0]),
      mock_importer_result(false),
      mock_importer_result(true, @albums[2])
    )

    Music::Albums::WizardImportAlbumsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "completed", manager.step_status("import")
    assert_equal 2, manager.step_metadata("import")["imported_count"]
    assert_equal 1, manager.step_metadata("import")["failed_count"]
  end

  test "custom_html: updates progress periodically" do
    mock_importer_success_sequential

    Music::Albums::WizardImportAlbumsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal 100, manager.step_progress("import")
  end

  test "custom_html: updates wizard_step_status to completed with stats" do
    mock_importer_success_sequential

    Music::Albums::WizardImportAlbumsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "completed", manager.step_status("import")
    assert_equal 100, manager.step_progress("import")
    assert_equal 3, manager.step_metadata("import")["imported_count"]
    assert_equal 0, manager.step_metadata("import")["failed_count"]
    assert manager.step_metadata("import")["imported_at"].present?
  end

  test "custom_html: handles empty list gracefully" do
    @list_items.each(&:destroy)
    @list_items.clear

    Music::Albums::WizardImportAlbumsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "completed", manager.step_status("import")
    assert_equal 0, manager.step_metadata("import")["imported_count"]
  end

  test "custom_html: skips items already linked" do
    @list_items.first.update!(listable_id: @albums[0].id)

    DataImporters::Music::Album::Importer.expects(:call).times(2).returns(
      mock_importer_result(true, @albums[1]),
      mock_importer_result(true, @albums[2])
    )

    Music::Albums::WizardImportAlbumsJob.new.perform(@list.id)
  end

  test "custom_html: stores errors array in metadata" do
    DataImporters::Music::Album::Importer.stubs(:call).returns(mock_importer_result(false))

    Music::Albums::WizardImportAlbumsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    errors = manager.step_metadata("import")["errors"]
    assert_equal 3, errors.length
    assert errors.first.key?("item_id")
    assert errors.first.key?("title")
    assert errors.first.key?("error")
  end

  test "job is idempotent - can retry safely" do
    mock_importer_success_sequential

    Music::Albums::WizardImportAlbumsJob.new.perform(@list.id)

    @list_items.each(&:reload)

    DataImporters::Music::Album::Importer.expects(:call).never

    Music::Albums::WizardImportAlbumsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "completed", manager.step_status("import")
    assert_equal 0, manager.step_metadata("import")["imported_count"]
  end

  test "custom_html: skips items with ai_match_invalid set to true" do
    @list_items.first.update!(metadata: @list_items.first.metadata.merge("ai_match_invalid" => "true"))

    DataImporters::Music::Album::Importer.expects(:call).times(2).returns(
      mock_importer_result(true, @albums[1]),
      mock_importer_result(true, @albums[2])
    )

    Music::Albums::WizardImportAlbumsJob.new.perform(@list.id)
  end

  private

  def mock_importer_success_sequential
    DataImporters::Music::Album::Importer.stubs(:call).returns(
      mock_importer_result(true, @albums[0]),
      mock_importer_result(true, @albums[1]),
      mock_importer_result(true, @albums[2])
    )
  end

  def mock_importer_result(success, album = nil)
    result = mock
    result.stubs(:success?).returns(success)
    result.stubs(:item).returns(album)
    result.stubs(:all_errors).returns(success ? [] : ["Import failed"])
    result
  end
end
