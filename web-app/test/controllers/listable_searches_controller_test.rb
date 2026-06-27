# frozen_string_literal: true

require "test_helper"

class ListableSearchesControllerTest < ActionDispatch::IntegrationTest
  setup do
    @user = users(:regular_user)
    host! Rails.application.config.domains[:music]
  end

  test "anonymous request returns 401" do
    get listable_search_path(listable_type: "Music::Album", q: "pink"), as: :json
    assert_response :unauthorized
  end

  test "signed-in returns serialized results for a supported type" do
    sign_in_as(@user, stub_auth: true)
    album = music_albums(:dark_side_of_the_moon)
    ::Search::Music::Search::AlbumAutocomplete.stubs(:call)
      .returns([{id: album.id.to_s, score: 10.0, source: {}}])

    get listable_search_path(listable_type: "Music::Album", q: "dark"), as: :json

    assert_response :success
    body = JSON.parse(response.body)
    assert_equal 1, body.size
    assert_equal album.id, body.first["value"]
    assert_includes body.first["text"], album.title
  end

  test "signed-in returns [] for an unsupported type" do
    sign_in_as(@user, stub_auth: true)
    get listable_search_path(listable_type: "Movies::Movie", q: "anything"), as: :json
    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  test "signed-in returns [] for a blank query" do
    sign_in_as(@user, stub_auth: true)
    get listable_search_path(listable_type: "Music::Album", q: ""), as: :json
    assert_response :success
    assert_equal [], JSON.parse(response.body)
  end

  test "delegates to Search::ListableAutocomplete with the request params" do
    sign_in_as(@user, stub_auth: true)
    Search::ListableAutocomplete.expects(:search)
      .with(listable_type: "Games::Game", query: "zelda").returns([])

    get listable_search_path(listable_type: "Games::Game", q: "zelda"), as: :json
    assert_response :success
  end

  test "response is never cached" do
    sign_in_as(@user, stub_auth: true)
    ::Search::Music::Search::AlbumAutocomplete.stubs(:call).returns([])

    get listable_search_path(listable_type: "Music::Album", q: "x"), as: :json

    assert_response :success
    assert_match(/no-store/, response.headers["Cache-Control"].to_s)
  end
end
