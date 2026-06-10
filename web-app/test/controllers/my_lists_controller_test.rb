require "test_helper"

class MyListsControllerTest < ActionDispatch::IntegrationTest
  BOM = "\uFEFF"

  setup do
    @user = users(:regular_user)
    @albums_favorites = user_lists(:regular_user_music_albums_favorites)
    @albums_listened = user_lists(:regular_user_music_albums_listened)
    @custom_albums = user_lists(:regular_user_custom_albums)
    host! Rails.application.config.domains[:music]
  end

  # --- index / dashboard ---

  test "anonymous request to the dashboard redirects to /" do
    get my_lists_path
    assert_redirected_to "/"
  end

  test "dashboard lists only the current domain's lists, defaults first then custom" do
    sign_in_as(@user, stub_auth: true)
    get my_lists_path
    assert_response :success

    body = response.body
    assert_includes body, "Favorite Albums"
    assert_includes body, "Listened To" # apostrophe is HTML-escaped in the title
    assert_includes body, "Favorite Songs"
    assert_includes body, "My Desert Island Picks"
    refute_includes body, "Favorite Games" # games list excluded on music domain

    # defaults first (albums then songs, by list_type), custom last
    positions = ["Favorite Albums", "Listened To", "Favorite Songs", "My Desert Island Picks"]
      .map { |name| body.index(name) }
    assert_equal positions, positions.sort
  end

  test "dashboard renders accurate item counts" do
    sign_in_as(@user, stub_auth: true)
    get my_lists_path
    # Favorite Albums has 3 items in the fixtures
    assert_includes response.body, "3 items"
  end

  test "dashboard counts come from a single grouped query (no per-row count)" do
    sign_in_as(@user, stub_auth: true)
    queries = []
    callback = ->(_n, _s, _f, _i, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") do
      get my_lists_path
    end
    count_queries = queries.select { |sql| sql.include?("COUNT(") && sql.include?("user_list_items") }
    assert_operator count_queries.size, :<=, 1, "expected at most one grouped count query"
  end

  test "dashboard selects the games layout on the games domain" do
    host! Rails.application.config.domains[:games]
    sign_in_as(@user, stub_auth: true)
    get my_lists_path
    assert_response :success
    assert_includes response.body, 'data-theme="abyss"' # games layout marker
    assert_includes response.body, "Favorite Games"
  end

  test "dashboard selects the music layout on the music domain" do
    sign_in_as(@user, stub_auth: true)
    get my_lists_path
    assert_includes response.body, 'data-theme="light"' # music layout marker
  end

  test "unknown host falls back to the music layout (books has no layout yet)" do
    host! "unknown.example.com"
    sign_in_as(@user, stub_auth: true)
    get my_lists_path
    assert_response :success
    assert_includes response.body, 'data-theme="light"'
  end

  test "dashboard responses are never cached" do
    sign_in_as(@user, stub_auth: true)
    get my_lists_path
    assert_includes response.headers["Cache-Control"].to_s, "no-store"
    assert_includes response.headers["Cache-Control"].to_s, "private"
  end

  # --- show ---

  test "owner can view their list" do
    sign_in_as(@user, stub_auth: true)
    get my_list_path(@albums_favorites)
    assert_response :success
    assert_includes response.body, "Favorite Albums"
  end

  test "non-owner gets a 404" do
    host! Rails.application.config.domains[:games]
    sign_in_as(@user, stub_auth: true)
    get my_list_path(user_lists(:admin_user_games_favorites))
    assert_response :not_found
  end

  test "viewing a list from another domain 404s instead of rendering in the wrong layout" do
    # @albums_favorites is a music list; request it on the games host.
    host! Rails.application.config.domains[:games]
    sign_in_as(@user, stub_auth: true)
    get my_list_path(@albums_favorites)
    assert_response :not_found
  end

  test "owner can view a games list on the games host" do
    host! Rails.application.config.domains[:games]
    sign_in_as(@user, stub_auth: true)
    get my_list_path(user_lists(:regular_user_games_favorites))
    assert_response :success
  end

  test "legacy /user_lists/:id alias resolves to the same owner-only show" do
    sign_in_as(@user, stub_auth: true)
    get user_list_path(@albums_favorites)
    assert_response :success
    assert_includes response.body, "Favorite Albums"
  end

  test "legacy /user_lists/:id alias 404s for a non-owner" do
    host! Rails.application.config.domains[:games]
    sign_in_as(@user, stub_auth: true)
    get user_list_path(user_lists(:admin_user_games_favorites))
    assert_response :not_found
  end

  test "anonymous show redirects to /" do
    get my_list_path(@albums_favorites)
    assert_redirected_to "/"
  end

  test "switching view_mode persists it on the list and re-renders" do
    sign_in_as(@user, stub_auth: true)
    get my_list_path(@albums_favorites, view_mode: "grid_view")
    assert_response :success
    assert_equal "grid_view", @albums_favorites.reload.view_mode

    # subsequent visit with no param renders the persisted mode
    get my_list_path(@albums_favorites)
    assert_equal "grid_view", @albums_favorites.reload.view_mode
  end

  test "all three view modes render for an albums list" do
    sign_in_as(@user, stub_auth: true)
    %w[default_view table_view grid_view].each do |mode|
      get my_list_path(@albums_favorites, view_mode: mode)
      assert_response :success, "view_mode #{mode} failed"
    end
  end

  test "table view renders for a songs list" do
    sign_in_as(@user, stub_auth: true)
    get my_list_path(user_lists(:regular_user_music_songs_favorites), view_mode: "table_view")
    assert_response :success
  end

  test "default and grid views render for a songs list (tabular fallback)" do
    sign_in_as(@user, stub_auth: true)
    %w[default_view grid_view].each do |mode|
      get my_list_path(user_lists(:regular_user_music_songs_favorites), view_mode: mode)
      assert_response :success, "songs view_mode #{mode} failed"
    end
  end

  test "games list renders all three view modes on the games domain" do
    host! Rails.application.config.domains[:games]
    sign_in_as(@user, stub_auth: true)
    %w[default_view table_view grid_view].each do |mode|
      get my_list_path(user_lists(:regular_user_games_favorites), view_mode: mode)
      assert_response :success, "games view_mode #{mode} failed"
    end
  end

  test "completed_on displays read-only on a completed_on_enabled list" do
    sign_in_as(@user, stub_auth: true)
    get my_list_path(@albums_listened, view_mode: "table_view")
    assert_response :success
    assert_includes response.body, "Completed" # column header
    assert_includes response.body, "February 01, 2026"
  end

  # --- ranking sort ---

  test "sort=ranking orders by primary ranking with unranked items last" do
    config = ranking_configurations(:music_albums_global)
    RankedItem.create!(ranking_configuration: config, item: music_albums(:abbey_road), rank: 1)
    RankedItem.create!(ranking_configuration: config, item: music_albums(:dark_side_of_the_moon), rank: 5)
    # thriller intentionally left unranked

    sign_in_as(@user, stub_auth: true)
    get my_list_path(@albums_favorites, view_mode: "table_view", sort: "ranking")
    assert_response :success

    assert_equal [
      music_albums(:abbey_road).id,
      music_albums(:dark_side_of_the_moon).id,
      music_albums(:thriller).id # unranked, last
    ], rendered_listable_ids(@albums_favorites)
  end

  test "default sort=position orders by stored position" do
    sign_in_as(@user, stub_auth: true)
    get my_list_path(@albums_favorites, view_mode: "table_view")
    assert_response :success
    assert_equal [
      music_albums(:dark_side_of_the_moon).id,
      music_albums(:abbey_road).id,
      music_albums(:thriller).id
    ], rendered_listable_ids(@albums_favorites)
  end

  test "sort=ranking degrades to position and hides the option when no primary config exists" do
    Music::Albums::RankingConfiguration.stubs(:default_primary).returns(nil)
    sign_in_as(@user, stub_auth: true)
    get my_list_path(@albums_favorites, view_mode: "table_view", sort: "ranking")
    assert_response :success
    # degrades to position order
    assert_equal [
      music_albums(:dark_side_of_the_moon).id,
      music_albums(:abbey_road).id,
      music_albums(:thriller).id
    ], rendered_listable_ids(@albums_favorites)
    # the Ranking toolbar option is hidden
    assert_select "a", text: "Ranking", count: 0
  end

  # --- CSV ---

  test "csv download is BOM-prefixed with per-listable columns and a sanitized filename" do
    sign_in_as(@user, stub_auth: true)
    get my_list_path(@albums_listened, format: :csv)
    assert_response :success
    assert_includes response.media_type, "text/csv"

    body = response.body
    assert body.start_with?(BOM), "expected a UTF-8 BOM prefix"
    header = body.delete_prefix(BOM).lines.first
    assert_includes header, "Position"
    assert_includes header, "Title"
    assert_includes header, "Artists"
    assert_includes header, "Completed On"
    assert_includes body, "2026-02-01" # completed_on value

    expected = "#{@albums_listened.name.parameterize}-#{Date.current.iso8601}.csv"
    assert_includes response.headers["Content-Disposition"].to_s, expected
  end

  test "songs csv omits the Completed On column" do
    sign_in_as(@user, stub_auth: true)
    get my_list_path(user_lists(:regular_user_music_songs_favorites), format: :csv)
    assert_response :success
    header = response.body.delete_prefix(BOM).lines.first
    refute_includes header, "Completed On"
  end

  private

  # Distinct listable ids in render order (rows/cards carry data-listable-id),
  # filtered to the items actually in this list.
  def rendered_listable_ids(list)
    target = list.user_list_items.pluck(:listable_id)
    response.body.scan(/data-listable-id="(\d+)"/).flatten.map(&:to_i)
      .uniq.select { |id| target.include?(id) }
  end
end
