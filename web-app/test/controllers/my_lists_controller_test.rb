require "test_helper"
require "active_record/testing/query_assertions"

class MyListsControllerTest < ActionDispatch::IntegrationTest
  include ActiveRecord::Assertions::QueryAssertions

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

  test "unknown host renders the books layout (detect_current_domain defaults to :books)" do
    host! "unknown.example.com"
    sign_in_as(@user, stub_auth: true)
    get my_lists_path
    assert_response :success
    assert_includes response.body, 'data-theme="books"'
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

  test "show wraps the item count and list in the list_items turbo frame so adds reload only it" do
    sign_in_as(@user, stub_auth: true)
    get my_list_path(@albums_favorites)
    assert_response :success
    assert_select "turbo-frame#list_items [data-testid='list-item-count']"
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

  test "legacy /user_lists/:id alias renders the list for its owner" do
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

  test "anonymous show 404s on a private list" do
    get my_list_path(@albums_favorites)
    assert_response :not_found
  end

  test "switching view_mode persists it on the list and re-renders" do
    sign_in_as(@user, stub_auth: true)
    get my_list_path(@albums_favorites, view_mode: "list_view")
    assert_response :success
    assert_equal "list_view", @albums_favorites.reload.view_mode

    # subsequent visit with no param renders the persisted mode
    get my_list_path(@albums_favorites)
    assert_equal "list_view", @albums_favorites.reload.view_mode
  end

  test "show renders each album's primary description in list_view" do
    sign_in_as(@user, stub_auth: true)
    get my_list_path(@albums_favorites, view_mode: "list_view")
    assert_response :success
    assert_includes response.body, descriptions(:dark_side_ai).content
  end

  test "show preloads descriptions rather than querying per row in list_view" do
    sign_in_as(@user, stub_auth: true)

    assert_queries_match(/FROM "descriptions"/, count: 1) do
      get my_list_path(@albums_favorites, view_mode: "list_view")
    end

    assert_response :success
  end

  test "a list that has never had a view mode set lands on grid" do
    sign_in_as(@user, stub_auth: true)
    assert_equal "grid_view", @albums_favorites.view_mode

    get my_list_path(@albums_favorites)
    assert_response :success
    assert_equal "grid_view", @albums_favorites.reload.view_mode
  end

  test "all three view modes render for an albums list" do
    sign_in_as(@user, stub_auth: true)
    %w[list_view table_view grid_view].each do |mode|
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
    %w[list_view grid_view].each do |mode|
      get my_list_path(user_lists(:regular_user_music_songs_favorites), view_mode: mode)
      assert_response :success, "songs view_mode #{mode} failed"
    end
  end

  test "games list renders all three view modes on the games domain" do
    host! Rails.application.config.domains[:games]
    sign_in_as(@user, stub_auth: true)
    %w[list_view table_view grid_view].each do |mode|
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

  test "an owner can edit each Books Read completion date in every view mode" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_read)
    item = user_list_items(:regular_user_books_item_3)
    sign_in_as(@user, stub_auth: true)

    %w[list_view table_view grid_view].each do |mode|
      get my_list_path(list, view_mode: mode)

      assert_response :success
      assert_select "dialog#completion-date-dialog", count: 1
      assert_select "button[data-action='user-list-completion#open'][data-item-id='#{item.id}'][data-item-title='#{item.listable.title}'][data-completed-on='2026-01-20']", count: 1
    end
  end

  test "completion-date editor is absent from non-capable Books lists" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)

    [user_lists(:regular_user_books_favorites), reading_books_list].each do |list|
      get my_list_path(list)

      assert_response :success
      assert_select "dialog#completion-date-dialog", count: 0
      assert_select "button[data-action='user-list-completion#open']", count: 0
    end
  end

  test "a non-owner cannot see the completion-date editor on a public Books Read list" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_read)
    list.update!(public: true)
    sign_in_as(users(:admin_user), stub_auth: true)

    get my_list_path(list)

    assert_response :success
    assert_select "dialog#completion-date-dialog", count: 0
    assert_select "button[data-action='user-list-completion#open']", count: 0
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

  # --- pagination ---

  test "list pagination is path-based" do
    sign_in_as(@user, stub_auth: true)

    get "/my/lists/#{@albums_favorites.id}"

    assert_equal "/my/lists/#{@albums_favorites.id}/page/2", @controller.view_assigns["pagy"].page_url(2)
  end

  test "resolves a path-based page" do
    seed_list_items(@albums_favorites, 100)
    sign_in_as(@user, stub_auth: true)

    get "/my/lists/#{@albums_favorites.id}/page/2"

    assert_response :success
    assert_equal 2, @controller.view_assigns["pagy"].page
  end

  test "query-string pagination still resolves the page" do
    seed_list_items(@albums_favorites, 100)
    sign_in_as(@user, stub_auth: true)

    get "/my/lists/#{@albums_favorites.id}?page=2"

    assert_response :success
    assert_equal 2, @controller.view_assigns["pagy"].page
  end

  test "404s for a page past the last page" do
    sign_in_as(@user, stub_auth: true)

    get "/my/lists/#{@albums_favorites.id}/page/999999"

    assert_response :not_found
  end

  test "dashboard backfills missing default lists for the current domain" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)

    assert_difference -> { @user.user_lists.where(type: "Books::UserList").count }, 2 do
      get my_lists_path
    end
    assert_response :success
  end

  # --- books domain ---

  test "dashboard selects the books layout on the books domain" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)
    get my_lists_path
    assert_response :success
    assert_includes response.body, 'data-theme="books"'
  end

  test "books layout carries the user-list state controller and modal" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)
    get my_lists_path
    assert_response :success

    assert_includes response.body, 'data-controller="user-list-state membership-state"'
    assert_includes response.body, 'id="navbar_my_lists"'
    assert_includes response.body, 'id="user_list_modal"'
    assert_includes response.body, 'id="user-list-icons"'
  end

  test "show renders a books list on the books domain" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)
    get my_list_path(user_lists(:regular_user_books_favorites))
    assert_response :success
  end

  test "a books list 404s on the music domain" do
    sign_in_as(@user, stub_auth: true)
    get my_list_path(user_lists(:regular_user_books_favorites))
    assert_response :not_found
  end

  test "books CSV uses an Authors column and first_published_year" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)
    get my_list_path(user_lists(:regular_user_books_favorites), format: :csv)
    assert_response :success

    rows = CSV.parse(response.body.delete_prefix(BOM))
    assert_equal ["Position", "Title", "Authors", "Year"], rows.first
    assert_equal ["1", "War and Peace", "Leo Tolstoy", "1869"], rows.second
  end

  test "books CSV adds a Completed On column on a read list" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)
    get my_list_path(user_lists(:regular_user_books_read), format: :csv)
    assert_response :success

    rows = CSV.parse(response.body.delete_prefix(BOM))
    assert_equal ["Position", "Title", "Authors", "Year", "Completed On"], rows.first
    assert_equal "2026-01-20", rows.second.last
  end

  test "books grid view author loading does not scale with item count" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)
    list = user_lists(:regular_user_books_favorites)

    author_queries = ->(sql_log) { sql_log.count { |sql| sql.include?("books_book_authors") } }

    two_item_log = capture_sql { get my_list_path(list, view_mode: "grid_view") }
    assert_response :success

    list.user_list_items.create!(listable: books_books(:of_mice_and_men))
    list.user_list_items.create!(listable: books_books(:cannery_row))
    ActiveRecord::Base.connection.clear_query_cache

    four_item_log = capture_sql { get my_list_path(list, view_mode: "grid_view") }
    assert_response :success

    assert_equal author_queries.call(two_item_log), author_queries.call(four_item_log),
      "author queries scaled with item count — listable_display_includes is no longer preloading authors"
  end

  # --- public viewing ---

  test "anonymous viewer can read a public list" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_favorites)
    list.update!(public: true)

    get my_list_path(list)
    assert_response :success
  end

  test "anonymous viewer gets 404 on a private list" do
    host! Rails.application.config.domains[:books]
    get my_list_path(user_lists(:regular_user_books_favorites))
    assert_response :not_found
  end

  test "non-owner gets 404 on someone else's private list" do
    host! Rails.application.config.domains[:books]
    sign_in_as(users(:admin_user), stub_auth: true)

    get my_list_path(user_lists(:regular_user_books_favorites))
    assert_response :not_found
  end

  test "anonymous viewer gets 404 on a private list's csv" do
    host! Rails.application.config.domains[:books]
    get my_list_path(user_lists(:regular_user_books_favorites), format: :csv)
    assert_response :not_found
  end

  test "non-owner gets 404 on a private list's csv" do
    host! Rails.application.config.domains[:books]
    sign_in_as(users(:admin_user), stub_auth: true)

    get my_list_path(user_lists(:regular_user_books_favorites), format: :csv)
    assert_response :not_found
  end

  test "anonymous viewer gets 404 on the legacy alias for a private list" do
    host! Rails.application.config.domains[:books]
    get user_list_path(user_lists(:regular_user_books_favorites))
    assert_response :not_found
  end

  test "anonymous viewer can read a public list via the legacy alias" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_favorites)
    list.update!(public: true)

    get user_list_path(list)
    assert_response :success
  end

  test "non-owner reading a public list gets no add box and no backlink" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_favorites)
    list.update!(public: true)
    sign_in_as(users(:admin_user), stub_auth: true)

    get my_list_path(list)
    assert_response :success
    assert_no_match(/data-testid="add-item-search"/, response.body)
    assert_no_match(/data-testid="back-to-lists"/, response.body)
  end

  test "owner still gets the add box and backlink" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)

    get my_list_path(user_lists(:regular_user_books_favorites))
    assert_response :success
    assert_match(/data-testid="add-item-search"/, response.body)
    assert_match(/data-testid="back-to-lists"/, response.body)
  end

  test "a non-owner's view_mode param does not persist to the list" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_favorites)
    list.update!(public: true, view_mode: :list_view)
    sign_in_as(users(:admin_user), stub_auth: true)

    get my_list_path(list, view_mode: "grid_view")
    assert_response :success
    assert_equal "list_view", list.reload.view_mode
  end

  test "an owner's view_mode param does persist" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_favorites)
    list.update!(view_mode: :list_view)
    sign_in_as(@user, stub_auth: true)

    get my_list_path(list, view_mode: "grid_view")
    assert_equal "grid_view", list.reload.view_mode
  end

  test "CSV download works for a public list read by a non-owner" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_favorites)
    list.update!(public: true)
    sign_in_as(users(:admin_user), stub_auth: true)

    get my_list_path(list, format: :csv)
    assert_response :success
  end

  test "public list pages are never cached" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_favorites)
    list.update!(public: true)

    get my_list_path(list)
    assert_match(/no-store/, response.headers["Cache-Control"])
  end

  test "the dashboard still requires sign-in" do
    host! Rails.application.config.domains[:books]
    get my_lists_path
    assert_redirected_to "/"
  end

  test "a public list read by a non-owner shows the owner's display name" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_favorites)
    list.update!(public: true)
    list.user.update!(display_name: "Ada Lovelace")
    sign_in_as(users(:admin_user), stub_auth: true)

    get my_list_path(list)
    assert_match(/Ada Lovelace/, response.body)
  end

  test "attribution is omitted when the owner has no display name" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_favorites)
    list.update!(public: true)
    list.user.update_column(:display_name, nil)
    sign_in_as(users(:admin_user), stub_auth: true)

    get my_list_path(list)
    assert_response :success
    assert_no_match(/list-owner/, response.body)
    assert_no_match(Regexp.new(Regexp.escape(list.user.email)), response.body)
    assert_no_match(Regexp.new(Regexp.escape(list.user.name)), response.body)
  end

  test "the owner does not see attribution on their own list" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)

    get my_list_path(user_lists(:regular_user_books_favorites))
    assert_response :success
    assert_no_match(/list-owner/, response.body)
  end

  # --- legacy /user_lists redirects ---

  test "legacy /user_lists index 301s to /my/lists" do
    host! Rails.application.config.domains[:books]
    get "/user_lists"
    assert_response :moved_permanently
    assert_redirected_to "/my/lists"
  end

  test "legacy /user_lists/new 301s to /my/lists and is not read as an id" do
    host! Rails.application.config.domains[:books]
    get "/user_lists/new"
    assert_response :moved_permanently
    assert_redirected_to "/my/lists"
  end

  test "legacy /user_lists/:id/edit 301s to the read page" do
    host! Rails.application.config.domains[:books]
    list = user_lists(:regular_user_books_favorites)
    get "/user_lists/#{list.id}/edit"
    assert_response :moved_permanently
    assert_redirected_to "/my/lists/#{list.id}"
  end

  test "the /user_lists/:id alias still resolves to the show action" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)
    get "/user_lists/#{user_lists(:regular_user_books_favorites).id}"
    assert_response :success
  end

  # --- Turbo frame integrity ---
  #
  # Every link inside the list_items frame has to break out of it: the book,
  # album, game and song show pages have no list_items frame, so a link scoped
  # to the frame renders "Content missing". See CLAUDE.md, "Turbo Frames trap
  # links".

  test "no link in an albums list is trapped in the list_items frame" do
    sign_in_as(@user, stub_auth: true)

    %w[list_view table_view grid_view].each do |mode|
      assert_no_frame_trapped_links my_list_path(@albums_favorites, view_mode: mode)
    end
  end

  test "no link in a songs list is trapped in the list_items frame" do
    sign_in_as(@user, stub_auth: true)

    %w[list_view table_view grid_view].each do |mode|
      assert_no_frame_trapped_links my_list_path(
        user_lists(:regular_user_music_songs_favorites), view_mode: mode
      )
    end
  end

  test "no link in a books list is trapped in the list_items frame" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)

    %w[list_view table_view grid_view].each do |mode|
      assert_no_frame_trapped_links my_list_path(
        user_lists(:regular_user_books_favorites), view_mode: mode
      )
    end
  end

  test "no link in a games list is trapped in the list_items frame" do
    host! Rails.application.config.domains[:games]
    sign_in_as(@user, stub_auth: true)

    %w[list_view table_view grid_view].each do |mode|
      assert_no_frame_trapped_links my_list_path(
        user_lists(:regular_user_games_favorites), view_mode: mode
      )
    end
  end

  test "pagination stays inside the list_items frame" do
    seed_list_items(@albums_favorites, 100)
    sign_in_as(@user, stub_auth: true)

    get my_list_path(@albums_favorites)

    assert_response :success
    assert_select %(turbo-frame#list_items a[data-turbo-frame="list_items"]), minimum: 1
  end

  test "no link on a paginated list is trapped in the list_items frame" do
    seed_list_items(@albums_favorites, 100)
    sign_in_as(@user, stub_auth: true)

    assert_no_frame_trapped_links my_list_path(@albums_favorites)
  end

  private

  # Bulk-inserts filler albums + list items so pagination tests can reach page
  # 2+ against the controller's limit of 100, mirroring the books ranked_items
  # helper. insert_all skips callbacks deliberately (avoids search indexing).
  def seed_list_items(list, count)
    now = Time.current
    rows = Array.new(count) do |i|
      {title: "Filler Album #{i}", slug: "filler-album-#{list.id}-#{i}", created_at: now, updated_at: now}
    end
    ids = Music::Album.insert_all(rows, returning: :id).rows.flatten

    start_position = list.user_list_items.maximum(:position).to_i + 1
    UserListItem.insert_all(
      ids.each_with_index.map do |id, i|
        {user_list_id: list.id, listable_id: id, listable_type: "Music::Album",
         position: start_position + i, created_at: now, updated_at: now}
      end
    )
  end

  def reading_books_list
    list = Books::UserList.create!(
      user: @user,
      name: "Books I'm Reading",
      list_type: :reading
    )
    list.user_list_items.create!(listable: books_books(:war_and_peace))
    list
  end

  def capture_sql
    queries = []
    callback = ->(_n, _s, _f, _i, payload) { queries << payload[:sql] unless payload[:name] == "SCHEMA" }
    ActiveSupport::Notifications.subscribed(callback, "sql.active_record") { yield }
    queries
  end

  # Distinct listable ids in render order (rows/cards carry data-listable-id),
  # filtered to the items actually in this list.
  def rendered_listable_ids(list)
    target = list.user_list_items.pluck(:listable_id)
    response.body.scan(/data-listable-id="(\d+)"/).flatten.map(&:to_i)
      .uniq.select { |id| target.include?(id) }
  end
end
