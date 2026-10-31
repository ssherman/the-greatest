require "test_helper"

# Skips the session the way a cacheable page does, then asks for a marker.
class StateMarkerProbeController < ApplicationController
  include Cacheable

  def show
    skip_session_for_caching
    mark_user_state_changed
    render plain: "ok"
  end
end

class UserStateChangeMarkerTest < ActionDispatch::IntegrationTest
  self.use_transactional_tests = false

  setup do
    host! Rails.application.config.domains[:music]
    @user = users(:regular_user)
    @list = user_lists(:regular_user_music_albums_favorites)
    @album = music_albums(:wish_you_were_here)
    Rails.application.config.x.rate_limit_store.clear
  end

  def add_item
    post user_list_items_path(@list), params: {user_list_item: {listable_id: @album.id}}, as: :json
    assert_response :created
    cookies[:tg_state_mark]
  end

  test "a list item write sets tg_state_mark" do
    sign_in_as(@user, stub_auth: true)
    assert_nil cookies[:tg_state_mark]

    assert add_item.present?
  end

  test "a JSON write echoes the marker it set" do
    sign_in_as(@user, stub_auth: true)
    mark = add_item

    assert_equal mark, response.parsed_body["state_mark"]
  end

  test "a JSON write echoes the marker it arrived with" do
    sign_in_as(@user, stub_auth: true)
    first = add_item
    delete user_list_item_path(@list, UserListItem.find_by!(user_list: @list, listable: @album)), as: :json

    assert_equal first, response.parsed_body["state_mark_was"]
    assert_not_equal first, response.parsed_body["state_mark"]
  end

  test "a failed write sets no tg_state_mark" do
    sign_in_as(@user, stub_auth: true)
    mark = add_item

    # Adding the same item again is rejected as a duplicate.
    post user_list_items_path(@list), params: {user_list_item: {listable_id: @album.id}}, as: :json

    assert_response :conflict
    assert_equal mark, cookies[:tg_state_mark]
    assert_not_includes Array(response.headers["Set-Cookie"]).join("\n"), "tg_state_mark"
    assert_nil response.parsed_body["state_mark"]
  end

  test "a completion update sets tg_state_mark" do
    host! Rails.application.config.domains[:books]
    sign_in_as(@user, stub_auth: true)
    item = user_list_items(:regular_user_books_item_3)

    patch user_list_item_completion_path(item), params: {user_list_item: {completed_on: "2025-03-04"}}

    assert_response :see_other
    assert cookies[:tg_state_mark].present?
  end

  test "each write sets a different value" do
    sign_in_as(@user, stub_auth: true)
    first = add_item
    delete user_list_item_path(@list, UserListItem.find_by!(user_list: @list, listable: @album)), as: :json
    assert_response :success

    assert_not_equal first, cookies[:tg_state_mark]
  end

  test "creating a list sets tg_state_mark" do
    sign_in_as(@user, stub_auth: true)

    post user_lists_path, params: {user_list: {type: "Music::Albums::UserList", name: "Marked"}}, as: :json

    assert_response :created
    assert cookies[:tg_state_mark].present?
  end

  test "membership thanks sets tg_state_mark" do
    host! Rails.application.config.domains[:books]
    Services::Billing::ReconcileCustomer.stubs(:call)
    sign_in_as(@user, stub_auth: true)

    get membership_thanks_path

    assert_response :success
    assert cookies[:tg_state_mark].present?
  end

  test "a cacheable page sets no tg_state_mark" do
    with_routing do |set|
      set.draw { get "/state_marker_probe", to: "state_marker_probe#show" }
      get "/state_marker_probe"
      assert_response :success
      lines = Array(response.headers["Set-Cookie"]).flat_map { |h| h.to_s.split("\n") }
      assert_empty lines
    end
  end

  # Each site has its own layout, so each is checked.
  %i[books music games].each do |domain|
    test "an uncached #{domain} page carries the tg-page-request meta and a cacheable one does not" do
      host! Rails.application.config.domains[domain]
      sign_in_as(@user, stub_auth: true)
      get my_lists_path
      assert_response :success
      assert_select "meta[name='tg-page-request']"

      get "/"
      assert_response :success
      assert_select "meta[name='tg-page-request']", count: 0
    end
  end
end
