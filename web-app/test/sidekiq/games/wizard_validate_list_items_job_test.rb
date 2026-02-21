require "test_helper"

class Games::WizardValidateListItemsJobTest < ActiveSupport::TestCase
  setup do
    @list = lists(:games_list)
    @list.update!(wizard_state: {"current_step" => 3})
    @list.list_items.destroy_all

    @game = games_games(:breath_of_the_wild)
    @item = ListItem.create!(
      list: @list,
      listable_type: "Games::Game",
      listable_id: @game.id,
      position: 1,
      verified: false,
      metadata: {
        "title" => "Zelda BOTW",
        "developers" => ["Nintendo"],
        "game_id" => @game.id,
        "game_name" => @game.title,
        "opensearch_match" => true
      }
    )
  end

  test "job validates enriched items" do
    validation_result = Services::Ai::Result.new(
      success: true,
      data: {
        valid_count: 1,
        invalid_count: 0,
        verified_count: 1,
        total_count: 1,
        invalid_indices: [],
        reasoning: "All matches look correct"
      },
      ai_chat: nil
    )

    Services::Ai::Tasks::Lists::Games::ListItemsValidatorTask.any_instance
      .stubs(:call).returns(validation_result)

    Games::WizardValidateListItemsJob.new.perform(@list.id)

    @list.reload
    assert_equal "completed", @list.wizard_manager.step_status("validate")

    metadata = @list.wizard_manager.step_metadata("validate")
    assert_equal 1, metadata["valid_count"]
    assert_equal 0, metadata["invalid_count"]
  end

  test "job completes with no items when none are enriched" do
    @item.update!(listable_id: nil, metadata: {"title" => "Test"})

    Games::WizardValidateListItemsJob.new.perform(@list.id)

    @list.reload
    assert_equal "completed", @list.wizard_manager.step_status("validate")
    metadata = @list.wizard_manager.step_metadata("validate")
    assert_equal 0, metadata["validated_items"]
  end

  test "job sets failed status on validation error" do
    validation_result = Services::Ai::Result.new(
      success: false,
      error: "Validation failed"
    )

    Services::Ai::Tasks::Lists::Games::ListItemsValidatorTask.any_instance
      .stubs(:call).returns(validation_result)

    Games::WizardValidateListItemsJob.new.perform(@list.id)

    @list.reload
    assert_equal "failed", @list.wizard_manager.step_status("validate")
  end

  test "job detects enriched items by igdb_id" do
    @item.update!(listable_id: nil, metadata: @item.metadata.merge("igdb_id" => 123))

    validation_result = Services::Ai::Result.new(
      success: true,
      data: {
        valid_count: 1,
        invalid_count: 0,
        verified_count: 1,
        total_count: 1,
        invalid_indices: [],
        reasoning: nil
      },
      ai_chat: nil
    )

    Services::Ai::Tasks::Lists::Games::ListItemsValidatorTask.any_instance
      .stubs(:call).returns(validation_result)

    Games::WizardValidateListItemsJob.new.perform(@list.id)

    @list.reload
    assert_equal "completed", @list.wizard_manager.step_status("validate")
  end
end
