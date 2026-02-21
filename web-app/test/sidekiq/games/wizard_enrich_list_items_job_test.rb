require "test_helper"

class Games::WizardEnrichListItemsJobTest < ActiveSupport::TestCase
  setup do
    @list = lists(:games_list)
    @list.update!(wizard_state: {"current_step" => 2})
    @list.list_items.destroy_all

    @item = ListItem.create!(
      list: @list,
      listable_type: "Games::Game",
      position: 1,
      verified: false,
      metadata: {"title" => "Zelda BOTW", "developers" => ["Nintendo"], "release_year" => 2017}
    )
  end

  test "job enriches items and updates wizard state" do
    enrichment_result = {
      success: true,
      source: :opensearch,
      game_id: games_games(:breath_of_the_wild).id,
      data: {"game_id" => games_games(:breath_of_the_wild).id, "game_name" => "The Legend of Zelda: Breath of the Wild"}
    }

    Services::Lists::Games::ListItemEnricher.stubs(:call).returns(enrichment_result)

    Games::WizardEnrichListItemsJob.new.perform(@list.id)

    @list.reload
    assert_equal "completed", @list.wizard_manager.step_status("enrich")

    metadata = @list.wizard_manager.step_metadata("enrich")
    assert_equal 1, metadata["opensearch_matches"]
  end

  test "job tracks IGDB matches" do
    enrichment_result = {
      success: true,
      source: :igdb,
      data: {"igdb_id" => 123, "igdb_name" => "Test Game"}
    }

    Services::Lists::Games::ListItemEnricher.stubs(:call).returns(enrichment_result)

    Games::WizardEnrichListItemsJob.new.perform(@list.id)

    @list.reload
    metadata = @list.wizard_manager.step_metadata("enrich")
    assert_equal 1, metadata["igdb_matches"]
  end

  test "job tracks not found items" do
    enrichment_result = {success: false, source: :not_found, data: {}}

    Services::Lists::Games::ListItemEnricher.stubs(:call).returns(enrichment_result)

    Games::WizardEnrichListItemsJob.new.perform(@list.id)

    @list.reload
    metadata = @list.wizard_manager.step_metadata("enrich")
    assert_equal 1, metadata["not_found"]
  end

  test "job clears previous enrichment data before re-enriching" do
    @item.update!(
      listable_id: games_games(:breath_of_the_wild).id,
      metadata: @item.metadata.merge("game_id" => 1, "opensearch_match" => true, "igdb_id" => 123)
    )

    enrichment_result = {success: false, source: :not_found, data: {}}
    Services::Lists::Games::ListItemEnricher.stubs(:call).returns(enrichment_result)

    Games::WizardEnrichListItemsJob.new.perform(@list.id)

    @item.reload
    assert_nil @item.listable_id
    assert_nil @item.metadata["game_id"]
    assert_nil @item.metadata["opensearch_match"]
    assert_nil @item.metadata["igdb_id"]
  end

  test "job handles zero items" do
    @item.destroy!

    Games::WizardEnrichListItemsJob.new.perform(@list.id)

    @list.reload
    assert_equal "failed", @list.wizard_manager.step_status("enrich")
  end
end
