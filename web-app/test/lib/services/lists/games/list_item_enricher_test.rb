require "test_helper"

class Services::Lists::Games::ListItemEnricherTest < ActiveSupport::TestCase
  setup do
    @list = lists(:games_list)
    @game = games_games(:breath_of_the_wild)
    @item = ListItem.create!(
      list: @list,
      listable_type: "Games::Game",
      position: 1,
      verified: false,
      metadata: {
        "title" => "The Legend of Zelda: Breath of the Wild",
        "developers" => ["Nintendo"],
        "release_year" => 2017
      }
    )
  end

  test "enriches from opensearch when match found" do
    opensearch_result = [{id: @game.id.to_s, score: 12.5}]
    Search::Games::Search::GameByTitleAndDevelopers.stubs(:call).returns(opensearch_result)

    result = Services::Lists::Games::ListItemEnricher.call(list_item: @item)

    assert result[:success]
    assert_equal :opensearch, result[:source]

    @item.reload
    assert_equal @game.id, @item.listable_id
    assert_equal @game.id, @item.metadata["game_id"]
    assert_equal @game.title, @item.metadata["game_name"]
    assert @item.metadata["opensearch_match"]
    assert_equal 12.5, @item.metadata["opensearch_score"]
  end

  test "falls back to IGDB when opensearch finds nothing" do
    Search::Games::Search::GameByTitleAndDevelopers.stubs(:call).returns([])

    igdb_result = {
      success: true,
      data: [
        {
          "id" => 7346,
          "name" => "The Legend of Zelda: Breath of the Wild",
          "involved_companies" => [
            {"developer" => true, "company" => {"name" => "Nintendo EPD"}}
          ]
        }
      ]
    }

    Games::Igdb::Search::GameSearch.any_instance.stubs(:search_by_name).returns(igdb_result)
    Games::Game.stubs(:with_igdb_id).returns(Games::Game.none)

    result = Services::Lists::Games::ListItemEnricher.call(list_item: @item)

    assert result[:success]
    assert_equal :igdb, result[:source]

    @item.reload
    assert_equal 7346, @item.metadata["igdb_id"]
    assert_equal "The Legend of Zelda: Breath of the Wild", @item.metadata["igdb_name"]
    assert_equal ["Nintendo EPD"], @item.metadata["igdb_developer_names"]
    assert @item.metadata["igdb_match"]
    assert_nil @item.listable_id # no local game matches
  end

  test "links to existing game when IGDB match has local game" do
    Search::Games::Search::GameByTitleAndDevelopers.stubs(:call).returns([])

    igdb_result = {
      success: true,
      data: [{"id" => 7346, "name" => "Zelda", "involved_companies" => []}]
    }

    Games::Igdb::Search::GameSearch.any_instance.stubs(:search_by_name).returns(igdb_result)

    scope = Games::Game.where(id: @game.id)
    Games::Game.stubs(:with_igdb_id).with(7346).returns(scope)

    result = Services::Lists::Games::ListItemEnricher.call(list_item: @item)

    assert result[:success]
    @item.reload
    assert_equal @game.id, @item.listable_id
    assert_equal @game.id, @item.metadata["game_id"]
  end

  test "returns not found when no match exists" do
    Search::Games::Search::GameByTitleAndDevelopers.stubs(:call).returns([])
    Games::Igdb::Search::GameSearch.any_instance.stubs(:search_by_name)
      .returns({success: false, data: nil})

    result = Services::Lists::Games::ListItemEnricher.call(list_item: @item)

    assert_not result[:success]
    assert_equal :not_found, result[:source]
  end

  test "returns not found when title is blank" do
    @item.update!(metadata: {"title" => "", "developers" => ["Nintendo"]})

    result = Services::Lists::Games::ListItemEnricher.call(list_item: @item)

    assert_not result[:success]
    assert_equal :not_found, result[:source]
  end

  test "enriches by title only when developers is blank" do
    @item.update!(metadata: {"title" => "Zelda", "developers" => []})

    # OpenSearch is tried first (title-only search)
    Search::Games::Search::GameByTitleAndDevelopers.stubs(:call).returns([])

    igdb_result = {
      success: true,
      data: [
        {
          "id" => 7346,
          "name" => "The Legend of Zelda",
          "involved_companies" => [
            {"developer" => true, "company" => {"name" => "Nintendo"}}
          ]
        }
      ]
    }

    Games::Igdb::Search::GameSearch.any_instance.stubs(:search_by_name).returns(igdb_result)
    Games::Game.stubs(:with_igdb_id).returns(Games::Game.none)

    result = Services::Lists::Games::ListItemEnricher.call(list_item: @item)

    assert result[:success]
    assert_equal :igdb, result[:source]
    @item.reload
    assert_equal 7346, @item.metadata["igdb_id"]
  end

  test "enriches by title only via opensearch when developers is blank" do
    @item.update!(metadata: {"title" => "Zelda", "developers" => []})

    opensearch_result = [{id: @game.id.to_s, score: 9.0}]
    Search::Games::Search::GameByTitleAndDevelopers.stubs(:call).returns(opensearch_result)

    result = Services::Lists::Games::ListItemEnricher.call(list_item: @item)

    assert result[:success]
    assert_equal :opensearch, result[:source]
    @item.reload
    assert_equal @game.id, @item.listable_id
  end

  test "uses developers key instead of artists" do
    # Verify the enricher reads from "developers" metadata key
    @item.update!(metadata: {"title" => "Zelda", "developers" => ["Nintendo"], "artists" => ["Wrong"]})

    opensearch_result = [{id: @game.id.to_s, score: 10.0}]
    Search::Games::Search::GameByTitleAndDevelopers.expects(:call)
      .with(title: "Zelda", artists: ["Nintendo"], size: 1, min_score: 5.0)
      .returns(opensearch_result)

    Services::Lists::Games::ListItemEnricher.call(list_item: @item)
  end
end
