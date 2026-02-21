require "test_helper"

class Games::WizardImportGamesJobTest < ActiveSupport::TestCase
  setup do
    @list = lists(:games_list)
    @list.update!(wizard_state: {"current_step" => 5, "import_source" => "custom_html"})
    @list.list_items.destroy_all

    @item = ListItem.create!(
      list: @list,
      listable_type: "Games::Game",
      position: 1,
      verified: true,
      metadata: {
        "title" => "Celeste",
        "developers" => ["Maddy Makes Games"],
        "igdb_id" => 25076,
        "igdb_name" => "Celeste",
        "igdb_match" => true
      }
    )
  end

  test "job imports games from IGDB" do
    game = games_games(:breath_of_the_wild)
    import_result = OpenStruct.new(success?: true, item: game, all_errors: [])

    DataImporters::Games::Game::Importer.stubs(:call).with(igdb_id: 25076).returns(import_result)

    Games::WizardImportGamesJob.new.perform(@list.id)

    @item.reload
    assert_equal game.id, @item.listable_id
    assert @item.verified
    assert_equal game.id, @item.metadata["imported_game_id"]
    assert_not_nil @item.metadata["imported_at"]

    @list.reload
    assert_equal "completed", @list.wizard_manager.step_status("import")
    metadata = @list.wizard_manager.step_metadata("import")
    assert_equal 1, metadata["imported_count"]
    assert_equal 0, metadata["failed_count"]
  end

  test "job skips items already linked" do
    @item.update!(listable_id: games_games(:half_life_2).id)

    Games::WizardImportGamesJob.new.perform(@list.id)

    @list.reload
    assert_equal "completed", @list.wizard_manager.step_status("import")
    metadata = @list.wizard_manager.step_metadata("import")
    assert_equal 0, metadata["total_items"]
  end

  test "job skips items without igdb_id" do
    @item.update!(metadata: @item.metadata.except("igdb_id"))

    Games::WizardImportGamesJob.new.perform(@list.id)

    @list.reload
    assert_equal "completed", @list.wizard_manager.step_status("import")
    metadata = @list.wizard_manager.step_metadata("import")
    assert_equal 0, metadata["total_items"]
  end

  test "job handles import failure gracefully" do
    import_result = OpenStruct.new(success?: false, item: nil, all_errors: ["API error"])

    DataImporters::Games::Game::Importer.stubs(:call).returns(import_result)

    Games::WizardImportGamesJob.new.perform(@list.id)

    @list.reload
    assert_equal "completed", @list.wizard_manager.step_status("import")
    metadata = @list.wizard_manager.step_metadata("import")
    assert_equal 0, metadata["imported_count"]
    assert_equal 1, metadata["failed_count"]
  end

  test "job completes with no items when nothing to import" do
    @item.destroy!

    Games::WizardImportGamesJob.new.perform(@list.id)

    @list.reload
    assert_equal "completed", @list.wizard_manager.step_status("import")
    metadata = @list.wizard_manager.step_metadata("import")
    assert_equal 0, metadata["total_items"]
  end

  test "job skips items marked as ai_match_invalid" do
    @item.update!(metadata: @item.metadata.merge("ai_match_invalid" => true))

    Games::WizardImportGamesJob.new.perform(@list.id)

    @list.reload
    metadata = @list.wizard_manager.step_metadata("import")
    assert_equal 0, metadata["total_items"]
  end
end
