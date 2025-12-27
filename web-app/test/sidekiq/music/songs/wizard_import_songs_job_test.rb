require "test_helper"

class Music::Songs::WizardImportSongsJobTest < ActiveSupport::TestCase
  setup do
    @list = lists(:music_songs_list)
    @list.update!(wizard_state: {"current_step" => 5, "import_source" => "custom_html"})

    @list.list_items.destroy_all

    @songs = [music_songs(:time), music_songs(:money), music_songs(:wish_you_were_here)]

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
          "artists" => ["Artist #{i + 1}"],
          "mb_recording_id" => "mb-recording-#{i + 1}"
        }
      )
    end
  end

  teardown do
    @list_items&.each { |item| item.destroy if item.persisted? }
  end

  test "job updates wizard_step_status to running at start" do
    mock_importer_success_sequential

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_includes ["running", "completed"], manager.step_status("import")
  end

  test "job dispatches based on import_source in wizard_state" do
    @list.update!(wizard_state: {"import_source" => "musicbrainz_series"})

    DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries.expects(:call)
      .with(list: @list)
      .returns({success: true, imported_count: 5, total_count: 5, results: []})

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)
  end

  test "job raises error when list not found" do
    assert_raises(ActiveRecord::RecordNotFound) do
      Music::Songs::WizardImportSongsJob.new.perform(999999)
    end
  end

  test "custom_html: processes only items with mb_recording_id and no listable_id" do
    item_without_mb_id = ListItem.create!(
      list: @list,
      listable_type: "Music::Song",
      listable_id: nil,
      verified: false,
      position: 10,
      metadata: {"title" => "No MB ID Song"}
    )

    DataImporters::Music::Song::Importer.expects(:call).times(3).returns(
      mock_importer_result(true, @songs[0]),
      mock_importer_result(true, @songs[1]),
      mock_importer_result(true, @songs[2])
    )

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)

    item_without_mb_id.destroy
  end

  test "custom_html: calls DataImporters::Music::Song::Importer for each item" do
    DataImporters::Music::Song::Importer.expects(:call)
      .with(musicbrainz_recording_id: "mb-recording-1")
      .returns(mock_importer_result(true, @songs[0]))
    DataImporters::Music::Song::Importer.expects(:call)
      .with(musicbrainz_recording_id: "mb-recording-2")
      .returns(mock_importer_result(true, @songs[1]))
    DataImporters::Music::Song::Importer.expects(:call)
      .with(musicbrainz_recording_id: "mb-recording-3")
      .returns(mock_importer_result(true, @songs[2]))

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)
  end

  test "custom_html: sets listable_id on successful import" do
    mock_importer_success_sequential

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)

    @list_items.each_with_index do |item, i|
      item.reload
      assert_equal @songs[i].id, item.listable_id
    end
  end

  test "custom_html: sets verified to true on successful import" do
    mock_importer_success_sequential

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)

    @list_items.each do |item|
      item.reload
      assert item.verified
    end
  end

  test "custom_html: stores import timestamp in metadata" do
    mock_importer_success_sequential

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)

    @list_items.each do |item|
      item.reload
      assert item.metadata["imported_at"].present?
      assert item.metadata["imported_song_id"].present?
    end
  end

  test "custom_html: stores import error on failure" do
    DataImporters::Music::Song::Importer.stubs(:call).returns(mock_importer_result(false))

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)

    @list_items.each do |item|
      item.reload
      assert item.metadata["import_error"].present?
      assert item.metadata["import_attempted_at"].present?
    end
  end

  test "custom_html: continues after individual item failure" do
    DataImporters::Music::Song::Importer.stubs(:call).returns(
      mock_importer_result(true, @songs[0]),
      mock_importer_result(false),
      mock_importer_result(true, @songs[2])
    )

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "completed", manager.step_status("import")
    assert_equal 2, manager.step_metadata("import")["imported_count"]
    assert_equal 1, manager.step_metadata("import")["failed_count"]
  end

  test "custom_html: updates progress periodically" do
    mock_importer_success_sequential

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal 100, manager.step_progress("import")
  end

  test "custom_html: updates wizard_step_status to completed with stats" do
    mock_importer_success_sequential

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)

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

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "completed", manager.step_status("import")
    assert_equal 0, manager.step_metadata("import")["imported_count"]
  end

  test "custom_html: skips items already linked" do
    @list_items.first.update!(listable_id: @songs[0].id)

    DataImporters::Music::Song::Importer.expects(:call).times(2).returns(
      mock_importer_result(true, @songs[1]),
      mock_importer_result(true, @songs[2])
    )

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)
  end

  test "custom_html: stores errors array in metadata" do
    DataImporters::Music::Song::Importer.stubs(:call).returns(mock_importer_result(false))

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    errors = manager.step_metadata("import")["errors"]
    assert_equal 3, errors.length
    assert errors.first.key?("item_id")
    assert errors.first.key?("title")
    assert errors.first.key?("error")
  end

  test "series: calls ImportSongsFromMusicbrainzSeries service" do
    @list.update!(wizard_state: {"import_source" => "musicbrainz_series"})

    DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries.expects(:call)
      .with(list: @list)
      .returns({success: true, imported_count: 10, total_count: 12, results: []})

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)
  end

  test "series: stores service result in wizard_step_metadata" do
    @list.update!(wizard_state: {"import_source" => "musicbrainz_series"})

    DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries.stubs(:call)
      .returns({success: true, imported_count: 10, total_count: 12, results: []})

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "completed", manager.step_status("import")
    assert_equal 10, manager.step_metadata("import")["imported_count"]
    assert_equal 12, manager.step_metadata("import")["total_count"]
    assert_equal 2, manager.step_metadata("import")["failed_count"]
  end

  test "series: handles service failure gracefully" do
    @list.update!(wizard_state: {"import_source" => "musicbrainz_series"})

    DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries.stubs(:call)
      .returns({success: false, message: "Series not found", imported_count: 0, total_count: 0, results: []})

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "failed", manager.step_status("import")
    assert_equal "Series not found", manager.step_error("import")
  end

  test "series: includes list_items_created in metadata" do
    @list.update!(wizard_state: {"import_source" => "musicbrainz_series"})

    DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries.stubs(:call)
      .returns({success: true, imported_count: 15, total_count: 15, results: []})

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal 15, manager.step_metadata("import")["list_items_created"]
  end

  test "series: marks imported items as verified" do
    @list.update!(wizard_state: {"import_source" => "musicbrainz_series"})

    @list_items.first.update!(listable_id: @songs[0].id, verified: false)
    @list_items.second.update!(listable_id: @songs[1].id, verified: false)

    DataImporters::Music::Lists::ImportSongsFromMusicbrainzSeries.stubs(:call)
      .returns({success: true, imported_count: 2, total_count: 2, results: []})

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)

    @list_items.first.reload
    @list_items.second.reload
    assert @list_items.first.verified, "First item should be verified"
    assert @list_items.second.verified, "Second item should be verified"
  end

  test "job is idempotent - can retry safely" do
    mock_importer_success_sequential

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)

    @list_items.each(&:reload)

    DataImporters::Music::Song::Importer.expects(:call).never

    Music::Songs::WizardImportSongsJob.new.perform(@list.id)

    @list.reload
    manager = @list.wizard_manager
    assert_equal "completed", manager.step_status("import")
    assert_equal 0, manager.step_metadata("import")["imported_count"]
  end

  private

  def mock_importer_success_sequential
    DataImporters::Music::Song::Importer.stubs(:call).returns(
      mock_importer_result(true, @songs[0]),
      mock_importer_result(true, @songs[1]),
      mock_importer_result(true, @songs[2])
    )
  end

  def mock_importer_result(success, song = nil)
    result = mock
    result.stubs(:success?).returns(success)
    result.stubs(:item).returns(song)
    result.stubs(:all_errors).returns(success ? [] : ["Import failed"])
    result
  end
end
