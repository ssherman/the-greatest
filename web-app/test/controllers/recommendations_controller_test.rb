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
end
