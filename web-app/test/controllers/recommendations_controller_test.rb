# frozen_string_literal: true

require "test_helper"

class RecommendationsControllerTest < ActionDispatch::IntegrationTest
  # Fixtures: regular_user is a member (regular_user_monthly) and already has
  # favorites and read books; books_viewer_user has no membership and no lists.
  def setup
    host! "dev-new.thegreatestbooks.org"
    @member = users(:regular_user)
    @free = users(:books_viewer_user)
    @books = ::Books::Book.limit(60).to_a
  end

  def give_history(user, book = books_books(:got))
    list = ::Books::UserList.find_or_create_by!(user: user, list_type: :favorites) { |l| l.name = "Favorites" }
    ::UserListItem.create!(user_list: list, listable: book)
  end

  def stub_candidates(books)
    hits = books.each_with_index.map { |b, i| {id: b.id, score: 10.0 - i * 0.01, rank_position: i + 1} }
    ::Search::Books::Search::BookRecommendations.stubs(:call).returns(hits)
    ::Search::Books::Search::BookRecommendations.stubs(:ranked_only).returns(hits)
  end

  def engine_result
    Recommendations::Engine::Result.new(success?: true, errors: [], data: {items: [], profile: nil, signals_used: [], fallback: false, degraded: false})
  end

  test "signed out gets the pitch with no engine call" do
    Recommendations::Engine.expects(:call).never
    get recommendations_path
    assert_response :success
    assert_includes response.headers.fetch("Cache-Control"), "no-store"
    assert_nil @controller.view_assigns["items"]
  end

  test "a signed-in user with no favorites or read books is sent to wizard step 1" do
    sign_in_as @free, stub_auth: true
    get recommendations_path
    assert_redirected_to recommendations_wizard_path(step: 1)
  end

  test "a free account asks the engine for the free limit and a member for the member limit" do
    give_history(@free)
    knobs = Rails.application.config.x.recommendations

    Recommendations::Engine.expects(:call).with { |args| args[:limit] == knobs[:free_limit] }.returns(engine_result)
    sign_in_as @free, stub_auth: true
    get recommendations_path
    assert_response :success

    Recommendations::Engine.expects(:call).with { |args| args[:limit] == knobs[:member_limit] }.returns(engine_result)
    sign_in_as @member, stub_auth: true
    get recommendations_path
    assert_response :success
  end

  test "the member flag follows the account and the engine items are assigned" do
    give_history(@free)
    stub_candidates(@books)

    sign_in_as @free, stub_auth: true
    get recommendations_path
    assert_response :success
    assert_equal :ok, @controller.view_assigns["state"]
    assert_equal @books.size, @controller.view_assigns["items"].size
    assert_equal false, @controller.view_assigns["member"]

    sign_in_as @member, stub_auth: true
    get recommendations_path
    assert_response :success
    assert_equal :ok, @controller.view_assigns["state"]
    assert_equal @books.size, @controller.view_assigns["items"].size
    assert_equal true, @controller.view_assigns["member"]
  end

  test "the stored depth reaches the engine as a quality floor override" do
    ::Books::RecommendationConfig.for_user(@member).update!(criteria: {"depth" => "deep"})
    stub_candidates(@books.first(5))
    Recommendations::Engine.expects(:call).with { |args| args[:overrides] == {quality_floor: 0.5} }.returns(engine_result)
    sign_in_as @member, stub_auth: true
    get recommendations_path
    assert_response :success
  end

  test "an engine that finds nothing is no_matches, and a broken search is unavailable" do
    sign_in_as @member, stub_auth: true

    ::Search::Books::Search::BookRecommendations.stubs(:call).returns([])
    ::Search::Books::Search::BookRecommendations.stubs(:ranked_only).returns([])
    get recommendations_path
    assert_response :success
    assert_equal :no_matches, @controller.view_assigns["state"]

    ::Search::Books::Search::BookRecommendations.stubs(:call).raises(StandardError, "opensearch down")
    ::Search::Books::Search::BookRecommendations.stubs(:ranked_only).raises(StandardError, "opensearch down")
    get recommendations_path
    assert_response :success
    assert_equal :unavailable, @controller.view_assigns["state"]
  end

  test "a stored category that no longer exists does not break the side panel" do
    ::Books::RecommendationConfig.for_user(@member).update!(criteria: {"excluded_category_ids" => [999_999]})
    stub_candidates(@books.first(3))
    sign_in_as @member, stub_auth: true
    get recommendations_path
    assert_response :success
    assert @controller.view_assigns["groups"].any? { |g| g.values.any? { |v| v.include?("999999") } }
  end

  test "a host with no recommendation domain 404s" do
    host! Rails.application.config.domains[:music]
    get recommendations_path
    assert_response :not_found
  end

  test "wizard steps 1 and 2 render for any signed-in user" do
    sign_in_as @free, stub_auth: true
    get recommendations_wizard_path(step: 1)
    assert_response :success
    assert_equal 1, @controller.view_assigns["step"]
    get recommendations_wizard_path(step: 2)
    assert_response :success
  end

  test "steps 3 and 4 need a favorite or read book and bounce to step 2 with an alert" do
    sign_in_as @free, stub_auth: true
    get recommendations_wizard_path(step: 3)
    assert_redirected_to recommendations_wizard_path(step: 2)
    assert flash[:alert].present?
    get recommendations_wizard_path(step: 4)
    assert_redirected_to recommendations_wizard_path(step: 2)

    give_history(@free)
    get recommendations_wizard_path(step: 3)
    assert_response :success
    assert_equal [], @controller.view_assigns["unrated"].books
  end

  test "step 3 lists unrated read books" do
    list = ::Books::UserList.find_or_create_by!(user: @free, list_type: :read) { |l| l.name = "Read" }
    ::UserListItem.create!(user_list: list, listable: books_books(:got))
    sign_in_as @free, stub_auth: true
    get recommendations_wizard_path(step: 3)
    assert_response :success
    assert_equal [books_books(:got)], @controller.view_assigns["unrated"].books
  end

  test "a step outside 1-4 is not routable" do
    sign_in_as @free, stub_auth: true
    get "/recommendations/wizard/5"
    assert_response :not_found
  end

  test "the wizard is signed-in only" do
    get recommendations_wizard_path(step: 1)
    assert_response :redirect
  end

  test "search renders the frame of cards and skips the search for a blank query" do
    sign_in_as @free, stub_auth: true
    ::Search::Books::Search::BookGeneral.stubs(:call).returns([{id: books_books(:got).id.to_s, score: 1.0, source: {"title" => books_books(:got).title}}])
    get recommendations_search_path(q: "thrones")
    assert_response :success
    assert_select "turbo-frame#wizard_search_results[target='_top']"
    assert_equal [books_books(:got)], @controller.view_assigns["books"]

    ::Search::Books::Search::BookGeneral.expects(:call).never
    get recommendations_search_path(q: "   ")
    assert_response :success
    assert_equal [], @controller.view_assigns["books"]
  end

  test "an oversized query is accepted" do
    sign_in_as @free, stub_auth: true
    ::Search::Books::Search::BookGeneral.stubs(:call).returns([])
    get recommendations_search_path(q: "x" * 2000)
    assert_response :success
  end

  test "no link inside the wizard search frame is trapped" do
    sign_in_as @free, stub_auth: true
    ::Search::Books::Search::BookGeneral.stubs(:call).returns([{id: books_books(:got).id.to_s, score: 1.0, source: {"title" => books_books(:got).title}}])
    assert_no_frame_trapped_links recommendations_search_path(q: "thrones")
  end

  test "step 3 lists rated books with their reviews" do
    list = user_lists(:regular_user_books_read)
    ::UserListItem.create!(user_list: list, listable: books_books(:war_and_peace))
    sign_in_as @member, stub_auth: true
    get recommendations_wizard_path(step: 3)
    assert_response :success
    rated = @controller.view_assigns["rated"]
    pair = rated.find { |book, _| book == books_books(:war_and_peace) }
    assert_equal 5, pair.last.rating
    assert_equal reviews(:regular_user_war_and_peace), pair.last
  end

  def settings_params(overrides = {})
    {recommendation_config: {criteria: {
      depth: "deep", max_ranked_position: "250", book_length: ["1", "2"],
      first_year_published_gt: "1900", excluded_category_ids: [categories(:books_politics_subject).id.to_s],
      genre_match_mode: "all"
    }.merge(overrides)}}
  end

  test "the settings page is locked for a free account and editable for a member" do
    sign_in_as @free, stub_auth: true
    get recommendations_settings_path
    assert_response :success
    assert_equal true, @controller.view_assigns["locked"]

    sign_in_as @member, stub_auth: true
    get recommendations_settings_path
    assert_response :success
    assert_equal false, @controller.view_assigns["locked"]
  end

  test "a free account cannot save settings even by hand" do
    sign_in_as @free, stub_auth: true
    assert_no_difference "RecommendationConfig.count" do
      post recommendations_settings_path, params: settings_params
    end
    assert_redirected_to membership_path
  end

  test "a member saves settings and lands on the results" do
    sign_in_as @member, stub_auth: true
    assert_no_difference "RecommendationConfig.count" do
      post recommendations_settings_path, params: settings_params
    end
    assert_redirected_to recommendations_path
    criteria = ::Books::RecommendationConfig.for_user(@member).criteria
    assert_equal "deep", criteria["depth"]
    assert_equal 250, criteria["max_ranked_position"]
    assert_equal [1, 2], criteria["book_length"]
    assert_equal [categories(:books_politics_subject).id], criteria["excluded_category_ids"]
    assert_equal "all", criteria["genre_match_mode"]
    assert_nil criteria["ranked"], "ranked never enters the stored criteria"
  end

  test "saving balanced depth clears a stored depth" do
    ::Books::RecommendationConfig.for_user(@member).update!(criteria: {"depth" => "deep"})
    sign_in_as @member, stub_auth: true
    post recommendations_settings_path, params: settings_params(depth: "balanced")
    assert_nil ::Books::RecommendationConfig.for_user(@member).criteria["depth"]
  end

  test "criteria posted as a string is a 422, not a 500" do
    sign_in_as @member, stub_auth: true
    post recommendations_settings_path, params: {recommendation_config: {criteria: "garbage"}}
    assert_response :unprocessable_entity
  end

  test "reset destroys the config and returns to step 1" do
    sign_in_as @member, stub_auth: true
    assert_difference "RecommendationConfig.count", -1 do
      post recommendations_reset_path
    end
    assert_redirected_to recommendations_wizard_path(step: 1)
    assert_response :see_other
  end

  test "reset with no stored config is harmless" do
    sign_in_as @free, stub_auth: true
    assert_no_difference "RecommendationConfig.count" do
      post recommendations_reset_path
    end
    assert_redirected_to recommendations_wizard_path(step: 1)
  end

  test "the settings form skips a stored category that no longer exists" do
    ::Books::RecommendationConfig.for_user(@member).update!(criteria: {"included_category_ids" => [999_999]})
    sign_in_as @member, stub_auth: true
    get recommendations_settings_path
    assert_response :success
    assert_equal({}, @controller.view_assigns["picked_categories"])
  end
end
