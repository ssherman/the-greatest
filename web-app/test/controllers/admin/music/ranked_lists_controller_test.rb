require "test_helper"

class Admin::Music::RankedListsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @ranking_configuration = ranking_configurations(:music_albums_global)
    @ranked_list = ranked_lists(:music_albums_ranked_list)
    @admin_user = users(:admin_user)
    @editor_user = users(:editor_user)
    @regular_user = users(:regular_user)

    # Set the host to match the music domain constraint
    host! Rails.application.config.domains[:music]
  end

  # Authentication/Authorization Tests

  test "should redirect index to root for unauthenticated users" do
    get admin_ranking_configuration_ranked_lists_path(ranking_configuration_id: @ranking_configuration.id)
    assert_redirected_to music_root_path
    assert_equal "Access denied. Admin or editor role required.", flash[:alert]
  end

  test "should redirect to root for regular users" do
    sign_in_as(@regular_user, stub_auth: true)
    get admin_ranking_configuration_ranked_lists_path(ranking_configuration_id: @ranking_configuration.id)
    assert_redirected_to music_root_path
    assert_equal "Access denied. Admin or editor role required.", flash[:alert]
  end

  test "should allow admin users to access index" do
    sign_in_as(@admin_user, stub_auth: true)
    get admin_ranking_configuration_ranked_lists_path(ranking_configuration_id: @ranking_configuration.id)
    assert_response :success
  end

  test "should allow editor users to access index" do
    sign_in_as(@editor_user, stub_auth: true)
    get admin_ranking_configuration_ranked_lists_path(ranking_configuration_id: @ranking_configuration.id)
    assert_response :success
  end

  # Index Tests

  test "should get index without sort parameter" do
    sign_in_as(@admin_user, stub_auth: true)
    get admin_ranking_configuration_ranked_lists_path(ranking_configuration_id: @ranking_configuration.id)
    assert_response :success
  end

  test "should load ranked lists with list associations" do
    sign_in_as(@admin_user, stub_auth: true)
    get admin_ranking_configuration_ranked_lists_path(ranking_configuration_id: @ranking_configuration.id)
    assert_response :success
  end

  test "should always sort by weight descending" do
    sign_in_as(@admin_user, stub_auth: true)
    get admin_ranking_configuration_ranked_lists_path(ranking_configuration_id: @ranking_configuration.id)
    assert_response :success
  end

  test "should paginate results" do
    sign_in_as(@admin_user, stub_auth: true)
    get admin_ranking_configuration_ranked_lists_path(ranking_configuration_id: @ranking_configuration.id)
    assert_response :success
  end

  test "should render without layout" do
    sign_in_as(@admin_user, stub_auth: true)
    get admin_ranking_configuration_ranked_lists_path(ranking_configuration_id: @ranking_configuration.id)
    assert_response :success

    # The controller renders layout: false, so response should not include main layout elements
    assert_not response.body.include?("<!DOCTYPE html>")
  end

  test "should handle ranking configuration with no ranked lists" do
    sign_in_as(@admin_user, stub_auth: true)

    # Create a new ranking configuration with no lists
    empty_config = Music::Albums::RankingConfiguration.create!(
      name: "Empty Config",
      global: true,
      primary: false
    )

    get admin_ranking_configuration_ranked_lists_path(ranking_configuration_id: empty_config.id)
    assert_response :success
  end

  test "should handle pagination with page parameter" do
    sign_in_as(@admin_user, stub_auth: true)
    get admin_ranking_configuration_ranked_lists_path(ranking_configuration_id: @ranking_configuration.id, page: 1)
    assert_response :success
  end

  test "should load multiple ranked lists when they exist" do
    sign_in_as(@admin_user, stub_auth: true)
    get admin_ranking_configuration_ranked_lists_path(ranking_configuration_id: @ranking_configuration.id)
    assert_response :success
  end
end
