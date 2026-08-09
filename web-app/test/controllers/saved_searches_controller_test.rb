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
end
