require "test_helper"

class Admin::MembershipsControllerTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin_user)
    @editor = users(:editor_user)
    @membership = memberships(:regular_user_monthly)
    host! Rails.application.config.domains[:music]
  end

  test "an admin sees the index" do
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url
    assert_response :success
  end

  test "an editor is denied the index" do
    sign_in_as(@editor, stub_auth: true)
    get admin_memberships_url
    assert_response :redirect
  end

  test "a signed-out visitor is denied the index" do
    get admin_memberships_url
    assert_response :redirect
  end

  test "filters by source" do
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url(source: "comped")
    assert_response :success
  end

  test "filters by status" do
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url(status: "canceled")
    assert_response :success
  end

  test "filters to unattached rows" do
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url(attached: "false")
    assert_response :success
  end

  test "ignores a source that is not a known enum value" do
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url(source: "'; drop table memberships; --")
    assert_response :success
  end

  test "survives an array-valued search param" do
    # ?q[]=foo arrives as an Array; Reviews::MyReviewsQuery and
    # Admin::ReviewsBaseController both hit this exact shape.
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url("q" => ["cus_regular"])
    assert_response :success
  end

  test "searches by stripe customer id" do
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url(q: "cus_regular")
    assert_response :success
  end

  test "searches by user email" do
    sign_in_as(@admin, stub_auth: true)
    get admin_memberships_url(q: users(:regular_user).email)
    assert_response :success
  end

  test "an admin sees the detail page" do
    sign_in_as(@admin, stub_auth: true)
    get admin_membership_url(@membership)
    assert_response :success
  end

  test "an editor is denied the detail page" do
    sign_in_as(@editor, stub_auth: true)
    get admin_membership_url(@membership)
    assert_response :redirect
  end

  test "the index does not N+1 over users" do
    sign_in_as(@admin, stub_auth: true)
    # An extra row owned by a user setup never references, so the margin between
    # "preloaded" and "not preloaded" comes from real uncached SELECTs rather
    # than from which fixtures setup happened to warm the query cache with.
    Membership.create!(user: users(:contractor_user), source: :comped, status: :active)

    # includes(:user, :granted_by) is load-bearing: the table renders both in a
    # loop. Pinned at 7 with .includes present; deleting it raises this to 10
    # (a real margin of 3 uncached SELECTs, not the incidental margin of 1 an
    # earlier version of this test had from setup's own fixture-cache warming).
    assert_queries_count(7) { get admin_memberships_url }
  end
end
