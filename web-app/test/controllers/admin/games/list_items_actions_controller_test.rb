# frozen_string_literal: true

require "test_helper"

class Admin::Games::ListItemsActionsControllerTest < ActionDispatch::IntegrationTest
  setup do
    host! Rails.application.config.domains[:games]
    @list = lists(:games_list)
    @admin_user = users(:admin_user)
    sign_in_as(@admin_user, stub_auth: true)

    @list.list_items.destroy_all
    @item = @list.list_items.create!(
      listable_type: "Games::Game",
      verified: false,
      position: 1,
      metadata: {"title" => "Pokémon Go", "developers" => ["Niantic"], "rank" => 1}
    )
  end

  # link_igdb_game with numeric ID
  test "link_igdb_game links game by numeric ID" do
    mock_response = {
      success: true,
      data: [{
        "id" => 12515,
        "name" => "Pokémon Go",
        "involved_companies" => [
          {"developer" => true, "company" => {"name" => "Niantic"}}
        ]
      }]
    }

    Games::Igdb::Search::GameSearch.any_instance
      .stubs(:find_with_details)
      .with(12515)
      .returns(mock_response)

    post link_igdb_game_admin_games_list_item_path(list_id: @list.id, id: @item.id),
      params: {igdb_id: "12515"}

    assert_response :redirect
    @item.reload
    assert @item.verified?
    assert_equal 12515, @item.metadata["igdb_id"]
    assert_equal "Pokémon Go", @item.metadata["igdb_name"]
    assert_equal ["Niantic"], @item.metadata["igdb_developer_names"]
    assert @item.metadata["igdb_match"]
    assert @item.metadata["manual_igdb_link"]
  end

  # link_igdb_game with IGDB URL
  test "link_igdb_game links game by IGDB URL" do
    slug_response = {
      success: true,
      data: [{
        "id" => 12515,
        "name" => "Pokémon Go",
        "involved_companies" => [
          {"developer" => true, "company" => {"name" => "Niantic"}}
        ]
      }]
    }

    Games::Igdb::Search::GameSearch.any_instance
      .stubs(:find_by_slug)
      .with("pokemon-go")
      .returns(slug_response)

    post link_igdb_game_admin_games_list_item_path(list_id: @list.id, id: @item.id),
      params: {igdb_id: "https://www.igdb.com/games/pokemon-go"}

    assert_response :redirect
    @item.reload
    assert @item.verified?
    assert_equal 12515, @item.metadata["igdb_id"]
    assert_equal "Pokémon Go", @item.metadata["igdb_name"]
  end

  test "link_igdb_game handles URL with trailing slash" do
    slug_response = {
      success: true,
      data: [{"id" => 12515, "name" => "Pokémon Go", "involved_companies" => []}]
    }

    Games::Igdb::Search::GameSearch.any_instance
      .stubs(:find_by_slug)
      .with("pokemon-go")
      .returns(slug_response)

    post link_igdb_game_admin_games_list_item_path(list_id: @list.id, id: @item.id),
      params: {igdb_id: "https://www.igdb.com/games/pokemon-go/"}

    assert_response :redirect
    @item.reload
    assert_equal 12515, @item.metadata["igdb_id"]
  end

  test "link_igdb_game handles URL with query params" do
    slug_response = {
      success: true,
      data: [{"id" => 12515, "name" => "Pokémon Go", "involved_companies" => []}]
    }

    Games::Igdb::Search::GameSearch.any_instance
      .stubs(:find_by_slug)
      .with("pokemon-go")
      .returns(slug_response)

    post link_igdb_game_admin_games_list_item_path(list_id: @list.id, id: @item.id),
      params: {igdb_id: "https://www.igdb.com/games/pokemon-go?tab=reviews"}

    assert_response :redirect
    @item.reload
    assert_equal 12515, @item.metadata["igdb_id"]
  end

  test "link_igdb_game handles HTTP URL" do
    slug_response = {
      success: true,
      data: [{"id" => 12515, "name" => "Pokémon Go", "involved_companies" => []}]
    }

    Games::Igdb::Search::GameSearch.any_instance
      .stubs(:find_by_slug)
      .with("pokemon-go")
      .returns(slug_response)

    post link_igdb_game_admin_games_list_item_path(list_id: @list.id, id: @item.id),
      params: {igdb_id: "http://www.igdb.com/games/pokemon-go"}

    assert_response :redirect
    @item.reload
    assert_equal 12515, @item.metadata["igdb_id"]
  end

  # Error cases
  test "link_igdb_game returns error for empty input" do
    post link_igdb_game_admin_games_list_item_path(list_id: @list.id, id: @item.id),
      params: {igdb_id: ""}

    assert_response :redirect
    @item.reload
    assert_not @item.verified?
    assert_nil @item.metadata["igdb_id"]
  end

  test "link_igdb_game returns error for invalid input" do
    post link_igdb_game_admin_games_list_item_path(list_id: @list.id, id: @item.id),
      params: {igdb_id: "not valid"}

    assert_response :redirect
    @item.reload
    assert_not @item.verified?
    assert_nil @item.metadata["igdb_id"]
  end

  test "link_igdb_game returns error for non-IGDB URL" do
    post link_igdb_game_admin_games_list_item_path(list_id: @list.id, id: @item.id),
      params: {igdb_id: "https://example.com/games/123"}

    assert_response :redirect
    @item.reload
    assert_not @item.verified?
    assert_nil @item.metadata["igdb_id"]
  end

  test "link_igdb_game returns error when slug not found on IGDB" do
    slug_response = {success: true, data: []}

    Games::Igdb::Search::GameSearch.any_instance
      .stubs(:find_by_slug)
      .with("nonexistent-game-slug")
      .returns(slug_response)

    post link_igdb_game_admin_games_list_item_path(list_id: @list.id, id: @item.id),
      params: {igdb_id: "https://www.igdb.com/games/nonexistent-game-slug"}

    assert_response :redirect
    @item.reload
    assert_not @item.verified?
    assert_nil @item.metadata["igdb_id"]
  end

  test "link_igdb_game returns error when numeric ID not found" do
    mock_response = {success: true, data: []}

    Games::Igdb::Search::GameSearch.any_instance
      .stubs(:find_with_details)
      .with(99999)
      .returns(mock_response)

    post link_igdb_game_admin_games_list_item_path(list_id: @list.id, id: @item.id),
      params: {igdb_id: "99999"}

    assert_response :redirect
    @item.reload
    assert_not @item.verified?
    assert_nil @item.metadata["igdb_id"]
  end

  test "link_igdb_game accepts turbo stream format with numeric ID" do
    mock_response = {
      success: true,
      data: [{"id" => 12515, "name" => "Pokémon Go", "involved_companies" => []}]
    }

    Games::Igdb::Search::GameSearch.any_instance
      .stubs(:find_with_details)
      .with(12515)
      .returns(mock_response)

    post link_igdb_game_admin_games_list_item_path(list_id: @list.id, id: @item.id),
      params: {igdb_id: "12515"},
      headers: {"Accept" => "text/vnd.turbo-stream.html"}

    assert_response :success
    @item.reload
    assert_equal 12515, @item.metadata["igdb_id"]
  end

  test "link_igdb_game accepts turbo stream format with URL" do
    slug_response = {
      success: true,
      data: [{"id" => 12515, "name" => "Pokémon Go", "involved_companies" => []}]
    }

    Games::Igdb::Search::GameSearch.any_instance
      .stubs(:find_by_slug)
      .with("pokemon-go")
      .returns(slug_response)

    post link_igdb_game_admin_games_list_item_path(list_id: @list.id, id: @item.id),
      params: {igdb_id: "https://www.igdb.com/games/pokemon-go"},
      headers: {"Accept" => "text/vnd.turbo-stream.html"}

    assert_response :success
    @item.reload
    assert_equal 12515, @item.metadata["igdb_id"]
  end

  test "link_igdb_game trims whitespace from input" do
    mock_response = {
      success: true,
      data: [{"id" => 12515, "name" => "Pokémon Go", "involved_companies" => []}]
    }

    Games::Igdb::Search::GameSearch.any_instance
      .stubs(:find_with_details)
      .with(12515)
      .returns(mock_response)

    post link_igdb_game_admin_games_list_item_path(list_id: @list.id, id: @item.id),
      params: {igdb_id: "  12515  "}

    assert_response :redirect
    @item.reload
    assert_equal 12515, @item.metadata["igdb_id"]
  end

  # Modal tests
  test "modal returns link_igdb_id content" do
    get modal_admin_games_list_item_path(list_id: @list.id, id: @item.id, modal_type: :link_igdb_id)

    assert_response :success
    assert_match "Link by IGDB ID", response.body
    assert_match "turbo-frame", response.body
    assert_match Admin::Games::Wizard::SharedModalComponent::FRAME_ID, response.body
  end

  test "modal returns search_igdb_games content" do
    get modal_admin_games_list_item_path(list_id: @list.id, id: @item.id, modal_type: :search_igdb_games)

    assert_response :success
    assert_match "Search IGDB Games", response.body
  end

  test "modal returns error for invalid modal type" do
    get modal_admin_games_list_item_path(list_id: @list.id, id: @item.id, modal_type: :invalid_type)

    assert_response :success
    assert_match "Invalid modal type", response.body
  end
end
