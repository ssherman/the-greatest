require "test_helper"
require "active_record/testing/query_assertions"

class SavedSearchesControllerTest < ActionDispatch::IntegrationTest
  include ActiveRecord::Assertions::QueryAssertions

  setup do
    @user = users(:regular_user)
    @other = users(:admin_user)
    @public_search = saved_searches(:books_public)
    @private_search = saved_searches(:books_private)
    @other_search = saved_searches(:books_other_user)
    host! Rails.application.config.domains[:books]
  end

  # --- index ---

  test "anonymous request to the index redirects to sign in" do
    get saved_searches_path
    assert_redirected_to "/"
  end

  test "index lists only the current user's searches" do
    sign_in_as(@user, stub_auth: true)
    get saved_searches_path
    assert_response :success

    assert_includes response.body, "Great Russian Novels"
    assert_includes response.body, "Search #{@private_search.id}"  # display_name fallback
    refute_includes response.body, "Someone else&#39;s search"
  end

  test "index orders by last executed, nulls last, then newest created" do
    sign_in_as(@user, stub_auth: true)
    get saved_searches_path

    executed = response.body.index("Great Russian Novels")
    never_run = response.body.index("Search #{@private_search.id}")
    assert_operator executed, :<, never_run
  end

  test "index renders the public badge and the last-run time" do
    sign_in_as(@user, stub_auth: true)
    get saved_searches_path

    assert_includes response.body, "Public"
    assert_includes response.body, "Last run 2 days ago"
  end

  # result_count is stale by construction and no longer written (spec §6/§9).
  test "index shows no result count" do
    sign_in_as(@user, stub_auth: true)
    get saved_searches_path

    refute_includes response.body, "42 results"
  end

  test "index is never cached" do
    sign_in_as(@user, stub_auth: true)
    get saved_searches_path

    assert_includes response.headers["Cache-Control"], "no-store"
  end

  # summary must stay lookup-free -- it renders once per row.
  test "index does not query per row" do
    sign_in_as(@user, stub_auth: true)
    get saved_searches_path  # warm the schema and session lookups

    # Fixtures wrap the test in a transaction with the query cache already
    # enabled pool-wide, so identical SQL from the warm-up request above would
    # otherwise be served from cache on the second call and never hit the
    # notification counter below -- same pattern as books/lists_controller_test.rb.
    ActiveRecord::Base.connection.clear_query_cache
    assert_queries_count(4) { get saved_searches_path }
  end

  test "index 404s on a domain with no saved searches" do
    host! Rails.application.config.domains[:music]
    sign_in_as(@user, stub_auth: true)
    get saved_searches_path

    assert_response :not_found
  end

  test "index renders the books layout" do
    sign_in_as(@user, stub_auth: true)
    get saved_searches_path

    assert_includes response.body, 'data-theme="books"'
  end

  test "index page 1 redirects to the bare path" do
    sign_in_as(@user, stub_auth: true)
    get "/searches/page/1"

    assert_redirected_to "/searches"
    assert_equal 301, response.status
  end

  # --- show ---

  # BookAdvanced is stubbed, per house style -- the query layer has its own
  # tests against a real test index. These tests are about the controller.
  def stub_advanced(ids:, total:)
    ::Search::Books::Search::BookAdvanced.stubs(:call).returns({ids: ids, total: total})
  end

  test "the owner sees a private search" do
    stub_advanced(ids: [books_books(:war_and_peace).id], total: 1)
    sign_in_as(@user, stub_auth: true)
    get saved_search_path(@private_search)

    assert_response :success
    assert_includes response.body, "War and Peace"
  end

  test "anonymous visitors see a public search" do
    stub_advanced(ids: [books_books(:war_and_peace).id], total: 1)
    get saved_search_path(@public_search)

    assert_response :success
    assert_includes response.body, "Great Russian Novels"
  end

  test "a private search 404s for another user" do
    sign_in_as(@other, stub_auth: true)
    get saved_search_path(@private_search)

    assert_response :not_found
  end

  test "a private search 404s for an anonymous visitor" do
    get saved_search_path(@private_search)

    assert_response :not_found
  end

  test "show renders the active-filters card with named taxonomies" do
    stub_advanced(ids: [], total: 0)
    get saved_search_path(@public_search)

    assert_includes response.body, "Active filters"
    assert_includes response.body, "Including languages"
    assert_includes response.body, languages(:russian).name
  end

  test "show renders an empty state when nothing matches" do
    stub_advanced(ids: [], total: 0)
    get saved_search_path(@public_search)

    assert_response :success
    assert_includes response.body, "No books match this search"
  end

  test "show reports the total" do
    stub_advanced(ids: [books_books(:war_and_peace).id], total: 1)
    get saved_search_path(@public_search)

    assert_includes response.body, "1 result"
  end

  test "a total at the window ceiling renders as 10,000+" do
    stub_advanced(ids: [books_books(:war_and_peace).id], total: 10_000)
    get saved_search_path(@public_search)

    assert_includes response.body, "10,000+ results"
  end

  test "show writes last_executed_at, without touching updated_at" do
    stub_advanced(ids: [], total: 0)
    before = @public_search.updated_at
    travel_to 1.hour.from_now do
      get saved_search_path(@public_search)
    end

    @public_search.reload
    assert_operator @public_search.last_executed_at, :>, 1.minute.ago
    assert_equal before.to_i, @public_search.updated_at.to_i
  end

  test "a page past the last one 404s and records no execution" do
    stub_advanced(ids: [], total: 50)
    before = @public_search.last_executed_at
    get saved_search_page_path(@public_search, 3)

    assert_response :not_found
    assert_equal before.to_i, @public_search.reload.last_executed_at.to_i
  end

  # Legacy paged with ?page=N. Those links must keep working, and both forms
  # must land on the same page -- pagy_path_request merges query params with
  # the route's :page and Rails' params[:page] prefers the route segment, so
  # the page the controller sends OpenSearch and the page pagy renders agree.
  # Asserted through the rendered nav rather than a Mocha argument matcher,
  # which would have to match keyword args and is brittle about it.
  test "the path and query forms of a page resolve identically" do
    stub_advanced(ids: [], total: 500)

    get saved_search_page_path(@public_search, 2)
    assert_response :success
    assert_includes response.body, "Page 2 of 10"
    assert_includes response.body, "/searches/#{@public_search.id}/page/3"

    get "#{saved_search_path(@public_search)}?page=2"
    assert_response :success
    assert_includes response.body, "Page 2 of 10"
    # The nav canonicalises the query-string URL into the path form.
    assert_includes response.body, "/searches/#{@public_search.id}/page/3"
  end

  test "show page 1 redirects to the bare path" do
    get "/searches/#{@public_search.id}/page/1"

    assert_redirected_to "/searches/#{@public_search.id}"
    assert_equal 301, response.status
  end

  test "show is never cached" do
    stub_advanced(ids: [], total: 0)
    get saved_search_path(@public_search)

    assert_includes response.headers["Cache-Control"], "no-store"
  end

  test "show is noindex" do
    stub_advanced(ids: [], total: 0)
    get saved_search_path(@public_search)

    assert_includes response.body, 'name="robots" content="noindex, follow"'
  end

  # The grid renders authors and a cover per book -- the exact N+1 shape.
  test "show does not query per result book" do
    ids = [books_books(:war_and_peace).id, books_books(:crime_and_punishment).id]
    stub_advanced(ids: ids, total: 2)
    get saved_search_path(@public_search)  # warm

    # Fixtures wrap the test in a transaction with the query cache already
    # enabled pool-wide, so identical SQL from the warm-up request above would
    # otherwise be served from cache on the second call and never hit the
    # notification counter below -- same pattern as books/lists_controller_test.rb.
    ActiveRecord::Base.connection.clear_query_cache
    stub_advanced(ids: ids, total: 2)
    assert_queries_count(9) { get saved_search_path(@public_search) }
  end

  test "show 404s on a domain with no saved searches" do
    host! Rails.application.config.domains[:music]
    get saved_search_path(@public_search)

    assert_response :not_found
  end
end
