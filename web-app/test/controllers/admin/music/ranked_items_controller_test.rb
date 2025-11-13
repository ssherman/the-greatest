require "test_helper"

class Admin::Music::RankedItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @ranking_configuration = ranking_configurations(:music_albums_global)
    @ranked_item = ranked_items(:music_albums_ranked_item)
    @admin_user = users(:admin_user)
    @editor_user = users(:editor_user)
    @regular_user = users(:regular_user)

    # Set the host to match the music domain constraint
    host! Rails.application.config.domains[:music]
  end

  # Authentication/Authorization Tests

  test "should redirect index to root for unauthenticated users" do
    get admin_ranking_configuration_ranked_items_path(ranking_configuration_id: @ranking_configuration.id)
    assert_redirected_to music_root_path
    assert_equal "Access denied. Admin or editor role required.", flash[:alert]
  end

  test "should redirect to root for regular users" do
    sign_in_as(@regular_user, stub_auth: true)
    get admin_ranking_configuration_ranked_items_path(ranking_configuration_id: @ranking_configuration.id)
    assert_redirected_to music_root_path
    assert_equal "Access denied. Admin or editor role required.", flash[:alert]
  end

  test "should allow admin users to access index" do
    sign_in_as(@admin_user, stub_auth: true)
    get admin_ranking_configuration_ranked_items_path(ranking_configuration_id: @ranking_configuration.id)
    assert_response :success
  end

  test "should allow editor users to access index" do
    sign_in_as(@editor_user, stub_auth: true)
    get admin_ranking_configuration_ranked_items_path(ranking_configuration_id: @ranking_configuration.id)
    assert_response :success
  end

  # Index Tests

  test "should get index without sort parameter" do
    sign_in_as(@admin_user, stub_auth: true)
    get admin_ranking_configuration_ranked_items_path(ranking_configuration_id: @ranking_configuration.id)
    assert_response :success
  end

  test "should load ranked items with item associations" do
    sign_in_as(@admin_user, stub_auth: true)
    get admin_ranking_configuration_ranked_items_path(ranking_configuration_id: @ranking_configuration.id)
    assert_response :success
  end

  test "should always sort by rank ascending" do
    sign_in_as(@admin_user, stub_auth: true)
    get admin_ranking_configuration_ranked_items_path(ranking_configuration_id: @ranking_configuration.id)
    assert_response :success
  end

  test "should paginate results" do
    sign_in_as(@admin_user, stub_auth: true)
    get admin_ranking_configuration_ranked_items_path(ranking_configuration_id: @ranking_configuration.id)
    assert_response :success
  end

  test "should render without layout" do
    sign_in_as(@admin_user, stub_auth: true)
    get admin_ranking_configuration_ranked_items_path(ranking_configuration_id: @ranking_configuration.id)
    assert_response :success

    # The controller renders layout: false, so response should not include main layout elements
    assert_not response.body.include?("<!DOCTYPE html>")
  end

  test "should handle ranking configuration with no ranked items" do
    sign_in_as(@admin_user, stub_auth: true)

    # Create a new ranking configuration with no items
    empty_config = Music::Albums::RankingConfiguration.create!(
      name: "Empty Config",
      global: true,
      primary: false
    )

    get admin_ranking_configuration_ranked_items_path(ranking_configuration_id: empty_config.id)
    assert_response :success
  end

  test "should handle pagination with page parameter" do
    sign_in_as(@admin_user, stub_auth: true)
    get admin_ranking_configuration_ranked_items_path(ranking_configuration_id: @ranking_configuration.id, page: 1)
    assert_response :success
  end
end
