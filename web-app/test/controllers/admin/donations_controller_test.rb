require "test_helper"

class Admin::DonationsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin_user)
    @editor = users(:editor_user)
    host! Rails.application.config.domains[:music]
  end

  test "an admin sees the index" do
    sign_in_as(@admin, stub_auth: true)
    get admin_donations_url
    assert_response :success
  end

  test "an editor is denied the index" do
    sign_in_as(@editor, stub_auth: true)
    get admin_donations_url
    assert_response :redirect
  end

  test "a signed-out visitor is denied the index" do
    get admin_donations_url
    assert_response :redirect
  end

  test "filters by status" do
    sign_in_as(@admin, stub_auth: true)
    get admin_donations_url(status: "succeeded")
    assert_response :success
    assert_equal [donations(:regular_user_gift).id, donations(:anonymous_gift).id,
      donations(:legacy_imported_no_intent).id].sort,
      @controller.view_assigns["donations"].map(&:id).sort
  end

  test "ignores a status that is not a known enum value" do
    sign_in_as(@admin, stub_auth: true)
    get admin_donations_url(status: "nonsense")
    assert_response :success
  end

  test "survives an array-valued search param" do
    sign_in_as(@admin, stub_auth: true)
    get admin_donations_url("q" => ["pi_regular_gift"])
    assert_response :success
  end

  test "searches by payment intent id" do
    sign_in_as(@admin, stub_auth: true)
    get admin_donations_url(q: "pi_regular_gift")
    assert_response :success
    assert_equal [donations(:regular_user_gift).id],
      @controller.view_assigns["donations"].map(&:id)
  end

  test "a literal percent sign in the search term is escaped, not treated as a wildcard" do
    sign_in_as(@admin, stub_auth: true)
    get admin_donations_url(q: "%")
    assert_response :success
    assert_equal [], @controller.view_assigns["donations"].map(&:id)
  end

  test "the index does not N+1 over donors" do
    sign_in_as(@admin, stub_auth: true)
    # An extra row owned by a user setup never references, so the margin between
    # "preloaded" and "not preloaded" comes from real uncached SELECTs rather
    # than from which fixtures setup happened to warm the query cache with.
    Donation.create!(user: users(:contractor_user), amount_cents: 750, status: :succeeded,
      stripe_payment_intent_id: "pi_contractor_gift", domain: "games")

    # includes(:user) is load-bearing: the table renders it in a loop. Pinned
    # at 6 with .includes present; deleting it raises this to 8 (a real margin
    # of 2 uncached SELECTs -- three donations have a user, so three individual
    # lookups replace the one batched IN query).
    assert_queries_count(6) { get admin_donations_url }
  end
end
