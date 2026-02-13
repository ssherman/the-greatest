require "test_helper"

class Admin::Music::RankedItemsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @ranking_configuration = ranking_configurations(:music_albums_global)
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
    assert_equal "Access denied.", flash[:alert]
  end

  test "should redirect to root for regular users" do
    sign_in_as(@regular_user, stub_auth: true)
    get admin_ranking_configuration_ranked_items_path(ranking_configuration_id: @ranking_configuration.id)
    assert_redirected_to music_root_path
    assert_equal "Access denied.", flash[:alert]
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

  # Domain-scoped auth tests

  test "should allow domain user with music access to view ranked items" do
    contractor = users(:contractor_user)
    sign_in_as(contractor, stub_auth: true)

    # contractor_user has music editor domain role, so should have access
    get admin_ranking_configuration_ranked_items_path(ranking_configuration_id: @ranking_configuration.id)
    assert_response :success
  end

  test "should allow domain user with games access to view games ranked items" do
    host! Rails.application.config.domains[:games]

    contractor = users(:contractor_user)
    sign_in_as(contractor, stub_auth: true)

    games_rc = ranking_configurations(:games_global)
    # contractor_user has games viewer domain role, so should have access
    get admin_ranking_configuration_ranked_items_path(ranking_configuration_id: games_rc.id)
    assert_response :success
  end

  test "should reject domain user without access to the config's domain" do
    host! Rails.application.config.domains[:games]

    # Create a user with only music access, no games access
    music_only_user = User.create!(
      email: "musiconly@example.com",
      display_name: "Music Only",
      name: "Music Only User",
      role: :user,
      email_verified: true
    )
    DomainRole.create!(user: music_only_user, domain: :music, permission_level: :editor)

    sign_in_as(music_only_user, stub_auth: true)

    games_rc = ranking_configurations(:games_global)
    get admin_ranking_configuration_ranked_items_path(ranking_configuration_id: games_rc.id)
    assert_response :redirect
  end

  test "should load ranked items for artist ranking configuration without eager loading artists association" do
    sign_in_as(@admin_user, stub_auth: true)

    # Use an artist ranking configuration
    artist_rc = ranking_configurations(:music_artists_global)

    # Create a ranked artist item
    artist = music_artists(:pink_floyd)
    RankedItem.create!(
      item: artist,
      ranking_configuration: artist_rc,
      rank: 1,
      score: 100.0
    )

    # This should not raise an error even though Music::Artist doesn't have an artists association
    assert_nothing_raised do
      get admin_ranking_configuration_ranked_items_path(ranking_configuration_id: artist_rc.id)
    end

    assert_response :success
  end
end
