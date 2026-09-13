require "test_helper"

class My::RankingConfigurations::ListsControllerTest < ActionDispatch::IntegrationTest
  TURBO = {"Accept" => "text/vnd.turbo-stream.html"}.freeze

  setup do
    host! Rails.application.config.domains[:books]
    @owner = users(:regular_user)
    @stranger = users(:editor_user)
    @config = ranking_configurations(:books_user)
    @primary = ranking_configurations(:books_global)
    @config.update_columns(needs_refresh: false)
    @official = Books::List.create!(name: "Official Only", source: "Guardian", year_published: 2003, status: :active)
    @mine = Books::List.create!(name: "Mine Already", source: "Time", status: :active)
    @other = Books::List.create!(name: "Unattached Active", source: "NYT", status: :active)
    @approved = Books::List.create!(name: "Approved Not Active", source: "NYT", status: :approved)
    RankedList.create!(list: @official, ranking_configuration: @primary, weight: 70)
    RankedList.create!(list: @mine, ranking_configuration: @config, weight: 55)
  end

  def count_queries
    count = 0
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |_name, _start, _finish, _id, payload|
      count += 1 unless ["SCHEMA", "TRANSACTION"].include?(payload[:name])
    end
    yield
    count
  ensure
    ActiveSupport::Notifications.unsubscribe(subscriber)
  end

  # --- index ---

  test "index requires sign-in and the owner" do
    get my_ranking_configuration_lists_path(@config)
    assert_redirected_to "/"

    sign_in_as @stranger, stub_auth: true
    get my_ranking_configuration_lists_path(@config)
    assert_response :not_found
  end

  test "index renders the owner's lists and the diff against the official ranking, uncached" do
    sign_in_as @owner, stub_auth: true

    get my_ranking_configuration_lists_path(@config)

    assert_response :success
    assert_match "no-store", response.headers["Cache-Control"].to_s
    assert_equal [@mine.id], @controller.view_assigns["ranked_lists"].map(&:list_id)
    assert_equal [@official.id], @controller.view_assigns["missing"].map(&:list_id)
  end

  test "index has no frame-trapped links" do
    sign_in_as @owner, stub_auth: true
    assert_no_frame_trapped_links my_ranking_configuration_lists_path(@config)
  end

  test "the lists page runs a bounded number of queries regardless of list count" do
    sign_in_as @owner, stub_auth: true
    baseline = count_queries { get my_ranking_configuration_lists_path(@config) }

    4.times { |i| @config.ranked_lists.create!(list: Books::List.create!(name: "Bulk #{i}", source: "T", status: :active)) }
    4.times { |i| RankedList.create!(list: Books::List.create!(name: "Missing #{i}", source: "T", status: :active), ranking_configuration: @primary, weight: i) }
    grown = count_queries { get my_ranking_configuration_lists_path(@config) }

    assert_equal baseline, grown, "query count grew with the number of lists (N+1)"
  end

  # --- search ---

  test "search returns active lists of the domain's type not already in the configuration" do
    sign_in_as @owner, stub_auth: true

    get search_my_ranking_configuration_lists_path(@config, q: "NYT"), as: :json
    assert_response :success
    values = response.parsed_body.map { |row| row["value"] }
    assert_includes values, @other.id
    refute_includes values, @approved.id
    refute_includes values, lists(:games_list).id

    get search_my_ranking_configuration_lists_path(@config, q: "Mine Already"), as: :json
    assert_empty response.parsed_body, "lists already in the configuration are excluded"

    get search_my_ranking_configuration_lists_path(@config, q: ""), as: :json
    assert_empty response.parsed_body
  end

  test "search rows carry the list id and its display name" do
    sign_in_as @owner, stub_auth: true

    get search_my_ranking_configuration_lists_path(@config, q: "Official Only"), as: :json

    row = response.parsed_body.first
    assert_equal @official.id, row["value"]
    assert_equal @official.name_with_source, row["text"]
  end

  test "search is owner-only" do
    sign_in_as @stranger, stub_auth: true
    get search_my_ranking_configuration_lists_path(@config, q: "NYT"), as: :json
    assert_response :not_found
  end

  # --- create / add_missing / destroy ---

  test "create adds the posted active lists, marks stale and replaces the frame" do
    sign_in_as @owner, stub_auth: true

    post my_ranking_configuration_lists_path(@config), params: {list_ids: [@other.id, @approved.id], page: 1}, headers: TURBO

    assert_response :success
    assert_equal "text/vnd.turbo-stream.html", response.media_type
    assert_includes response.body, 'target="rc_lists"'
    assert_equal [@mine.id, @other.id].sort, @config.ranked_lists.pluck(:list_id).sort
    assert @config.reload.needs_refresh?
  end

  test "create without a Turbo Stream accept redirects back to the lists page" do
    sign_in_as @owner, stub_auth: true

    post my_ranking_configuration_lists_path(@config), params: {list_ids: [@other.id]}

    assert_redirected_to my_ranking_configuration_lists_path(@config, page: 1)
  end

  test "add_missing adds every official list the configuration lacks" do
    sign_in_as @owner, stub_auth: true

    post add_missing_my_ranking_configuration_lists_path(@config), headers: TURBO

    assert_response :success
    assert_includes @config.ranked_lists.pluck(:list_id), @official.id
    assert_empty @controller.view_assigns["missing"]
    assert @config.reload.needs_refresh?
  end

  test "destroy removes the list, marks stale and the list reappears in the diff" do
    sign_in_as @owner, stub_auth: true
    RankedList.create!(list: @mine, ranking_configuration: @primary, weight: 10)

    delete my_ranking_configuration_list_path(@config, @mine.id), headers: TURBO

    assert_response :success
    assert_empty @config.ranked_lists
    assert @config.reload.needs_refresh?
    assert_includes @controller.view_assigns["missing"].map(&:list_id), @mine.id
  end

  test "destroy 404s for a list that is not in the configuration" do
    sign_in_as @owner, stub_auth: true
    delete my_ranking_configuration_list_path(@config, @other.id), headers: TURBO
    assert_response :not_found
  end

  test "a page past the end is clamped after a removal" do
    sign_in_as @owner, stub_auth: true

    delete my_ranking_configuration_list_path(@config, @mine.id), params: {page: 9}, headers: TURBO

    assert_response :success
    assert_equal 1, @controller.view_assigns["pagy"].page
  end

  test "a non-owner cannot add or remove lists" do
    sign_in_as @stranger, stub_auth: true

    post my_ranking_configuration_lists_path(@config), params: {list_ids: [@other.id]}, headers: TURBO
    assert_response :not_found
    delete my_ranking_configuration_list_path(@config, @mine.id), headers: TURBO
    assert_response :not_found

    assert_equal [@mine.id], @config.ranked_lists.pluck(:list_id)
  end
end
