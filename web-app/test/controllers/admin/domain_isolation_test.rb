require "test_helper"

# Tests that domain-scoped users cannot access global admin controllers.
# This ensures proper domain isolation - a music-only user should not be able
# to access global controllers that manage cross-domain resources.
class Admin::DomainIsolationTest < ActionDispatch::IntegrationTest
  setup do
    @admin = users(:admin_user)
    @editor = users(:editor_user)
    @contractor = users(:contractor_user)  # Has music domain role only

    host! Rails.application.config.domains[:music]
  end

  # Global admin controllers should require global admin/editor role

  test "domain-scoped user cannot access global penalties controller" do
    sign_in_as(@contractor, stub_auth: true)
    get admin_penalties_path
    assert_redirected_to music_root_path
    assert_equal "Access denied. Admin or editor role required.", flash[:alert]
  end

  test "domain-scoped user CAN access list items for lists in their domain" do
    sign_in_as(@contractor, stub_auth: true)
    list = lists(:music_albums_list)  # contractor has music domain role
    get admin_list_list_items_path(list)
    assert_response :success
  end

  test "domain-scoped user CAN access list penalties for lists in their domain" do
    sign_in_as(@contractor, stub_auth: true)
    list = lists(:music_albums_list)  # contractor has music domain role
    get admin_list_list_penalties_path(list)
    assert_response :success
  end

  test "user with no domain role cannot access list items controller" do
    regular = users(:regular_user)
    sign_in_as(regular, stub_auth: true)
    list = lists(:music_albums_list)
    get admin_list_list_items_path(list)
    assert_redirected_to music_root_path
  end

  test "user with no domain role cannot access list penalties controller" do
    regular = users(:regular_user)
    sign_in_as(regular, stub_auth: true)
    list = lists(:music_albums_list)
    get admin_list_list_penalties_path(list)
    assert_redirected_to music_root_path
  end

  # Domain-scoped controllers should allow domain role access

  test "domain-scoped user CAN access music admin dashboard" do
    sign_in_as(@contractor, stub_auth: true)
    get admin_root_path
    assert_response :success
  end

  test "domain-scoped user CAN access music albums controller" do
    sign_in_as(@contractor, stub_auth: true)
    get admin_albums_path
    assert_response :success
  end

  test "domain-scoped user CAN access music artists controller" do
    sign_in_as(@contractor, stub_auth: true)
    get admin_artists_path
    assert_response :success
  end

  # Global admin/editor should access everything

  test "global admin can access global penalties controller" do
    sign_in_as(@admin, stub_auth: true)
    get admin_penalties_path
    assert_response :success
  end

  test "global editor can access global penalties controller" do
    sign_in_as(@editor, stub_auth: true)
    get admin_penalties_path
    assert_response :success
  end

  test "global admin can access music admin" do
    sign_in_as(@admin, stub_auth: true)
    get admin_albums_path
    assert_response :success
  end

  test "global editor can access music admin" do
    sign_in_as(@editor, stub_auth: true)
    get admin_albums_path
    assert_response :success
  end
end
