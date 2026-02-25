require "test_helper"

class Services::Lists::Games::ListItemEnricherTest < ActiveSupport::TestCase
  setup do
    @list = lists(:games_list)
    @game = games_games(:breath_of_the_wild)
    # Remove the fixture list item that links games_list to breath_of_the_wild,
    # so our test item can be enriched to point at @game without a uniqueness violation.
    list_items(:games_item).destroy!
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

  test "falls back to IGDB with AI match when opensearch finds nothing" do
    Search::Games::Search::GameByTitleAndDevelopers.stubs(:call).returns([])

    igdb_results = [
      {
        "id" => 7346,
        "name" => "The Legend of Zelda: Breath of the Wild",
        "involved_companies" => [
          {"developer" => true, "company" => {"name" => "Nintendo EPD"}}
        ]
      }
    ]

    igdb_result = {success: true, data: igdb_results}
    Games::Igdb::Search::GameSearch.any_instance.stubs(:search_by_name).returns(igdb_result)
    Games::Game.stubs(:with_igdb_id).returns(Games::Game.none)

    ai_result = Services::Ai::Result.new(
      success: true,
      data: {best_match: igdb_results[0], best_match_index: 0, confidence: "high", reasoning: "Exact match"}
    )
    Services::Ai::Tasks::Games::IgdbSearchMatchTask.any_instance.stubs(:call).returns(ai_result)

    result = Services::Lists::Games::ListItemEnricher.call(list_item: @item)

    assert result[:success]
    assert_equal :igdb, result[:source]

    @item.reload
    assert_equal 7346, @item.metadata["igdb_id"]
    assert_equal "The Legend of Zelda: Breath of the Wild", @item.metadata["igdb_name"]
    assert_equal ["Nintendo EPD"], @item.metadata["igdb_developer_names"]
    assert @item.metadata["igdb_match"]
    assert_equal "high", @item.metadata["ai_match_confidence"]
    assert_equal "Exact match", @item.metadata["ai_match_reasoning"]
    assert_nil @item.listable_id # no local game matches
  end

  test "AI selects correct match from multiple IGDB results" do
    Search::Games::Search::GameByTitleAndDevelopers.stubs(:call).returns([])

    igdb_results = [
      {"id" => 1, "name" => "Zelda II: The Adventure of Link", "involved_companies" => []},
      {"id" => 2, "name" => "The Legend of Zelda", "involved_companies" => [
        {"developer" => true, "company" => {"name" => "Nintendo"}}
      ]},
      {"id" => 3, "name" => "The Legend of Zelda: Breath of the Wild", "involved_companies" => []}
    ]

    igdb_result = {success: true, data: igdb_results}
    Games::Igdb::Search::GameSearch.any_instance.stubs(:search_by_name).returns(igdb_result)
    Games::Game.stubs(:with_igdb_id).returns(Games::Game.none)

    ai_result = Services::Ai::Result.new(
      success: true,
      data: {best_match: igdb_results[1], best_match_index: 1, confidence: "high", reasoning: "Exact title match"}
    )
    Services::Ai::Tasks::Games::IgdbSearchMatchTask.any_instance.stubs(:call).returns(ai_result)

    result = Services::Lists::Games::ListItemEnricher.call(list_item: @item)

    assert result[:success]
    @item.reload
    assert_equal 2, @item.metadata["igdb_id"]
    assert_equal "The Legend of Zelda", @item.metadata["igdb_name"]
  end

  test "returns not found when AI says no match" do
    Search::Games::Search::GameByTitleAndDevelopers.stubs(:call).returns([])

    igdb_results = [
      {"id" => 1, "name" => "Some Unrelated Game", "involved_companies" => []}
    ]

    igdb_result = {success: true, data: igdb_results}
    Games::Igdb::Search::GameSearch.any_instance.stubs(:search_by_name).returns(igdb_result)

    ai_result = Services::Ai::Result.new(
      success: true,
      data: {best_match: nil, best_match_index: nil, confidence: "none", reasoning: "No results match"}
    )
    Services::Ai::Tasks::Games::IgdbSearchMatchTask.any_instance.stubs(:call).returns(ai_result)

    result = Services::Lists::Games::ListItemEnricher.call(list_item: @item)

    assert_not result[:success]
    assert_equal :not_found, result[:source]
  end

  test "falls back to first result when AI task fails" do
    Search::Games::Search::GameByTitleAndDevelopers.stubs(:call).returns([])

    igdb_results = [
      {
        "id" => 7346,
        "name" => "The Legend of Zelda: Breath of the Wild",
        "involved_companies" => [
          {"developer" => true, "company" => {"name" => "Nintendo EPD"}}
        ]
      }
    ]

    igdb_result = {success: true, data: igdb_results}
    Games::Igdb::Search::GameSearch.any_instance.stubs(:search_by_name).returns(igdb_result)
    Games::Game.stubs(:with_igdb_id).returns(Games::Game.none)

    ai_result = Services::Ai::Result.new(success: false, error: "API timeout")
    Services::Ai::Tasks::Games::IgdbSearchMatchTask.any_instance.stubs(:call).returns(ai_result)

    result = Services::Lists::Games::ListItemEnricher.call(list_item: @item)

    assert result[:success]
    assert_equal :igdb, result[:source]

    @item.reload
    assert_equal 7346, @item.metadata["igdb_id"]
    assert_nil @item.metadata["ai_match_confidence"]
    assert_nil @item.metadata["ai_match_reasoning"]
  end

  test "links to existing game when IGDB match has local game" do
    Search::Games::Search::GameByTitleAndDevelopers.stubs(:call).returns([])

    igdb_results = [{"id" => 7346, "name" => "Zelda", "involved_companies" => []}]
    igdb_result = {success: true, data: igdb_results}
    Games::Igdb::Search::GameSearch.any_instance.stubs(:search_by_name).returns(igdb_result)

    scope = Games::Game.where(id: @game.id)
    Games::Game.stubs(:with_igdb_id).with(7346).returns(scope)

    ai_result = Services::Ai::Result.new(
      success: true,
      data: {best_match: igdb_results[0], best_match_index: 0, confidence: "medium", reasoning: "Close match"}
    )
    Services::Ai::Tasks::Games::IgdbSearchMatchTask.any_instance.stubs(:call).returns(ai_result)

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

    Search::Games::Search::GameByTitleAndDevelopers.stubs(:call).returns([])

    igdb_results = [
      {
        "id" => 7346,
        "name" => "The Legend of Zelda",
        "involved_companies" => [
          {"developer" => true, "company" => {"name" => "Nintendo"}}
        ]
      }
    ]

    Games::Igdb::Search::GameSearch.any_instance.stubs(:search_by_name).returns({success: true, data: igdb_results})
    Games::Game.stubs(:with_igdb_id).returns(Games::Game.none)

    ai_result = Services::Ai::Result.new(
      success: true,
      data: {best_match: igdb_results[0], best_match_index: 0, confidence: "high", reasoning: "Match"}
    )
    Services::Ai::Tasks::Games::IgdbSearchMatchTask.any_instance.stubs(:call).returns(ai_result)

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
    @item.update!(metadata: {"title" => "Zelda", "developers" => ["Nintendo"], "artists" => ["Wrong"]})

    opensearch_result = [{id: @game.id.to_s, score: 10.0}]
    Search::Games::Search::GameByTitleAndDevelopers.expects(:call)
      .with(title: "Zelda", artists: ["Nintendo"], size: 1, min_score: 5.0)
      .returns(opensearch_result)

    Services::Lists::Games::ListItemEnricher.call(list_item: @item)
  end

  test "passes limit of 10 to IGDB search" do
    Search::Games::Search::GameByTitleAndDevelopers.stubs(:call).returns([])

    Games::Igdb::Search::GameSearch.any_instance.expects(:search_by_name)
      .with("The Legend of Zelda: Breath of the Wild", limit: 25, fields: Services::Lists::Games::ListItemEnricher::IGDB_SEARCH_FIELDS)
      .returns({success: false, data: nil})

    Services::Lists::Games::ListItemEnricher.call(list_item: @item)
  end
end
